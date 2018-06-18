module Presto.Core.Language.Runtime.Interpreter
  ( Runtime(..)
  , UIRunner
  , PermissionCheckRunner
  , PermissionTakeRunner
  , PermissionRunner(..)
  , run
  ) where

import Prelude

import Control.Monad.Except (throwError, runExcept)
import Control.Monad.Free (foldFree)
import Control.Monad.State.Trans as S
import Control.Monad.Trans.Class (lift)
import Control.Parallel (parOneOf)
import Data.Either (Either(..))
import Data.Exists (runExists)
import Data.Map (Map, insert, lookup)
import Data.NaturalTransformation (NaturalTransformation)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff, delay, forkAff)
import Effect.Aff.AVar (AVar, empty, put, read, take)
import Effect.Exception (Error, error)
import Foreign.JSON (parseJSON)
import Global.Unsafe (unsafeStringify)
import Presto.Core.Language.Runtime.API (APIRunner, runAPIInteraction)
import Presto.Core.LocalStorage (getValueFromLocalStore, setValueToLocalStore)
import Presto.Core.Types.Language.Flow (Control(..), ErrorHandler(..), Flow, FlowMethod, FlowMethodF(..), FlowWrapper(..), Store(..))
import Presto.Core.Types.Language.Interaction (InteractionF(..), Interaction, ForeignOut(..))
import Presto.Core.Types.Language.Storage (Key)
import Presto.Core.Types.Permission (Permission, PermissionResponse, PermissionStatus)

type AffError = (Error -> Effect Unit)
type AffSuccess s e = (s -> Effect Unit)

type St = AVar (Map String String)
type InterpreterSt a = S.StateT St Aff a

type UIRunner = String -> Aff String

type PermissionCheckRunner = Array Permission -> Aff PermissionStatus
type PermissionTakeRunner = Array Permission -> Aff (Array PermissionResponse)
data PermissionRunner = PermissionRunner PermissionCheckRunner PermissionTakeRunner

data Runtime = Runtime UIRunner PermissionRunner APIRunner

-- FIXME: can the effects on the interepreter of each type be more fine-grained?

readState :: InterpreterSt (Map String String)
readState = S.get >>= (lift <<< read)

updateState :: Key -> String -> InterpreterSt Unit
updateState key value = do
  stVar <- S.get
  st <- lift $ take stVar
  let st' = insert key value st
  lift $ put st' stVar

interpretUI :: UIRunner -> NaturalTransformation InteractionF (Aff)
interpretUI uiRunner (Request fgnIn nextF) = do
  json <- uiRunner $ unsafeStringify fgnIn
  case (runExcept (parseJSON json)) of
    Right fgnOut -> pure $ nextF $ ForeignOut fgnOut
    Left err -> throwError $ error $ show err

runUIInteraction :: UIRunner -> NaturalTransformation Interaction Aff
runUIInteraction uiRunner = foldFree (interpretUI uiRunner)

-- TODO: canceller support
forkFlow :: forall a. Runtime -> Flow a -> InterpreterSt (Control a)
forkFlow rt flow = do
  st <- S.get
  resultVar <- lift empty
  let m = S.evalStateT (run rt flow) st
  _ <- lift $ forkAff $ m >>= flip put resultVar
  pure $ Control resultVar

runErrorHandler :: forall s. ErrorHandler s -> InterpreterSt s
runErrorHandler (ThrowError msg) = throwError $ error msg
runErrorHandler (ReturnResult res) = pure res

interpret :: forall s. Runtime -> NaturalTransformation (FlowMethod s) InterpreterSt
interpret (Runtime _ _ apiRunner) (CallAPI apiInteractionF nextF) = do
  lift $ runAPIInteraction apiRunner apiInteractionF
    >>= (pure <<< nextF)

interpret (Runtime uiRunner _ _) (RunUI uiInteraction nextF) = do
  lift $ runUIInteraction uiRunner uiInteraction
    >>= (pure <<< nextF)

interpret (Runtime uiRunner _ _) (ForkUI uiInteraction next) = do
  void $ lift $ forkAff $ runUIInteraction uiRunner uiInteraction
  pure next

interpret _ (Get LocalStore key next) = lift $ getValueFromLocalStore key >>= (pure <<< next)

interpret _ (Get InMemoryStore key next) = do
  readState >>= (lookup key >>> next >>> pure)

interpret _ (Set LocalStore key value next) = do
  lift $ setValueToLocalStore key value
  pure next

interpret _ (Set InMemoryStore key value next) = do
  updateState key value *> pure next

interpret r (Fork flow nextF) = forkFlow r flow >>= (pure <<< nextF)

interpret _ (DoAff aff nextF) = lift aff >>= (pure <<< nextF)

interpret _ (Await (Control resultVar) nextF) = do
  lift (read resultVar) >>= (pure <<< nextF)

interpret _ (Delay duration next) = lift (delay duration) *> pure next

interpret rt (OneOf flows nextF) = do
  st <- S.get
  Tuple a s <- lift $ parOneOf (parFlow st <$> flows)
  S.put s
  pure $ nextF a
  where
    parFlow st flow = S.runStateT (run rt flow) st

interpret rt (HandleError flow nextF) =
  run rt flow >>= runErrorHandler >>= (pure <<< nextF)

interpret (Runtime _ (PermissionRunner check _) _) (CheckPermissions permissions nextF) = do
  lift $ check permissions >>= (pure <<< nextF)

interpret (Runtime _ (PermissionRunner _ take) _) (TakePermissions permissions nextF) = do
  lift $ take permissions >>= (pure <<< nextF)

run :: Runtime -> NaturalTransformation Flow InterpreterSt
run runtime = foldFree (\(FlowWrapper x) -> runExists (interpret runtime) x)
