module Test.Language.UIInteractionTest where

import Prelude

import Control.Monad.State.Trans as S
import Data.Either (Either(..))
import Data.Generic.Rep (class Generic)
import Data.Generic.Rep.Eq as GEq
import Data.Generic.Rep.Show as GShow
import Data.Map (empty)
import Effect.Aff (Aff)
import Effect.Exception (Error, error)
import Foreign.Class (class Decode, class Encode, encode)
import Foreign.Generic (defaultOptions, genericEncode)
import Presto.Core.Types.Language.Flow (Flow, evalUI, runUI)
import Presto.Core.Types.Language.Interaction (class Interact, defaultInteract)
import Presto.Core.Utils.Encoding (defaultDecode)
import Test.Runtime.Interpreter (mkStFgn, mkStVar, run)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

data StaticQRScreen = StaticQRScreen String
data StaticQRScreenAction = StaticQRScreenAbort | StaticQRScreenAction String

instance interactionStaticQrScreen :: Interact Error StaticQRScreen StaticQRScreenAction where
  interact a = defaultInteract a
instance showStaticQRScreenAction :: Show StaticQRScreenAction where
  show = GShow.genericShow
instance eqStaticQRScreenAction :: Eq StaticQRScreenAction where
  eq = GEq.genericEq

derive instance genericStaticQRScreen :: Generic StaticQRScreen _
instance encodeStaticQRScreen :: Encode StaticQRScreen where
  encode = genericEncode (defaultOptions { unwrapSingleConstructors = false })

derive instance genericStaticQRScreenAction :: Generic StaticQRScreenAction _
instance decodeStaticQRScreenAction :: Decode StaticQRScreenAction where
  decode = defaultDecode
instance encodeStaticQRScreenAction :: Encode StaticQRScreenAction where
  encode = genericEncode (defaultOptions { unwrapSingleConstructors = false })

qrFlow :: Flow StaticQRScreenAction
qrFlow = runUI $ StaticQRScreen "ABC"

qrConvertFlow :: Flow String
qrConvertFlow = evalUI (StaticQRScreen "ABC") from
  where
    from (StaticQRScreenAction x) = Right x
    from StaticQRScreenAbort = Left $ error "Invalid Action"

uiInteractionTest :: Aff Unit
uiInteractionTest = do
  stVar <- mkStVar $ mkStFgn 0 empty (encode (StaticQRScreenAction "ABC"))
  x <- S.evalStateT (run qrFlow) stVar
  x `shouldEqual` (StaticQRScreenAction "ABC")

uiInteractionWithConvertTest :: Aff Unit
uiInteractionWithConvertTest = do
  stVar <- mkStVar $ mkStFgn 0 empty (encode (StaticQRScreenAction "ABC"))
  x <- S.evalStateT (run qrConvertFlow) stVar
  x `shouldEqual` "ABC"

runTests :: Spec Unit
runTests = do
  describe "UI Interaction test" do
    it "UI Interaction test" uiInteractionTest
    it "UI Interaction with convert test" uiInteractionWithConvertTest
