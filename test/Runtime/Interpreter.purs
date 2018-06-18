module Test.Runtime.Interpreter where

import Prelude

import Control.Monad.Free (foldFree)
import Control.Monad.State.Trans (StateT, get, put, evalStateT, runStateT) as S
import Control.Monad.Trans.Class (lift)
import Control.Parallel (parOneOf)
import Data.Exists (runExists)
import Data.Map (Map, empty, insert, lookup)
import Data.Maybe (Maybe(..))
import Data.NaturalTransformation (NaturalTransformation)
import Data.Tuple (Tuple(..))
import Effect.Aff (Aff, delay, forkAff)
import Effect.Aff.AVar (AVar, new, put, read, take)
import Effect.Aff.AVar (empty) as AVar
import Effect.Class (liftEffect)
import Effect.Exception (throw)
import Foreign (Foreign)
import Presto.Core.Types.Language.Flow (ErrorHandler(..), Flow, FlowMethod, FlowWrapper(..), FlowMethodF(..), Control(..))
import Presto.Core.Types.Language.Interaction (ForeignIn(..), ForeignOut(..), Interaction, InteractionF(..))
import Presto.Core.Types.Language.Storage (Key)

type TestStore = Map String String

type St = { maxAcquirePermission :: Int
          , store :: TestStore
          , foreignOutMock :: Maybe Foreign
          }

type InterpreterSt a = S.StateT (AVar St) Aff a

mkSt :: Int -> TestStore -> St
mkSt a store = {maxAcquirePermission: a, store: store, foreignOutMock: Nothing}

mkStFgn :: Int -> TestStore -> Foreign -> St
mkStFgn a store fgn = {maxAcquirePermission: a, store: store, foreignOutMock: Just fgn}

mkEmptySt :: St
mkEmptySt = mkSt 0 empty

mkStVar :: St -> Aff (AVar St)
mkStVar = new

readSt :: InterpreterSt St
readSt = S.get >>= (lift <<< read)

updateSt :: Key -> String -> InterpreterSt Unit
updateSt key value = do
  stVar <- S.get
  st <- lift $ take stVar
  let newStore = insert key value st.store
  let st' = mkSt st.maxAcquirePermission newStore
  lift $ put st' stVar

runErrorHandler :: forall s. ErrorHandler s -> InterpreterSt s
runErrorHandler (ThrowError msg) = liftEffect $ throw msg
runErrorHandler (ReturnResult res) = pure res

interpretUIInteraction :: NaturalTransformation InteractionF (InterpreterSt)
interpretUIInteraction (Request (ForeignIn fgnIn) nextF) = do
  st <- readSt
  case st.foreignOutMock of
    Nothing -> liftEffect $ throw "Error in UI interaction."
    Just fgnOutMock -> pure $ nextF $ ForeignOut fgnOutMock

runUIInteraction :: NaturalTransformation Interaction (InterpreterSt)
runUIInteraction = foldFree interpretUIInteraction

interpretAPI :: NaturalTransformation InteractionF (InterpreterSt)
interpretAPI (Request (ForeignIn fgnIn) nextF) = do
  st <- readSt
  case st.foreignOutMock of
    Nothing -> liftEffect $ throw "ForeignOut mock is not set."
    Just fgnOutMock -> pure $ nextF $ ForeignOut fgnOutMock

runAPIInteraction :: NaturalTransformation Interaction (InterpreterSt)
runAPIInteraction = foldFree interpretAPI

-- TODO: canceller support
forkFlow :: forall a. Flow a -> InterpreterSt (Control a)
forkFlow flow = do
  stVar <- S.get
  resultVar <- lift AVar.empty
  let m = S.evalStateT (run flow) stVar
  _ <- lift $ forkAff $ m >>= flip put resultVar
  pure $ Control resultVar


interpret :: forall s. NaturalTransformation (FlowMethod s) (InterpreterSt)

interpret (RunUI uiInteraction nextF) = do
  runUIInteraction uiInteraction >>= (pure <<< nextF)

interpret (ForkUI uiInteraction next) = do
  void $ runUIInteraction uiInteraction
  pure next

interpret (CallAPI apiInteractionF nextF) =
  runAPIInteraction apiInteractionF >>= (pure <<< nextF)

interpret (Get _ key nextF) = do
  readSt >>= (pure <<< nextF <<< lookup key <<< _.store)

interpret (Set _ key value next) = updateSt key value *> pure next

interpret (Fork flow nextF) = forkFlow flow >>= (pure <<< nextF)

interpret (Await (Control resultVar) nextF) = do
  lift (read resultVar) >>= (pure <<< nextF)

interpret (DoAff aff nextF) = lift aff >>= (pure <<< nextF)

interpret (Delay duration next) = lift (delay duration) *> pure next

interpret (OneOf flows nextF) = do
  -- lift $ warn "oneOf does not work yet"
  st <- S.get
  Tuple a s <- lift $ parOneOf (parFlow st <$> flows)
  S.put s
  pure $ nextF a
  where
    parFlow st flow = S.runStateT (run flow) st

interpret (HandleError flow nextF) =
  run flow >>= runErrorHandler >>= (pure <<< nextF)

interpret _ = liftEffect $ throw $ "Interpreter not implemented."

run :: NaturalTransformation Flow (InterpreterSt)
run = foldFree (\(FlowWrapper x) -> runExists interpret x)
