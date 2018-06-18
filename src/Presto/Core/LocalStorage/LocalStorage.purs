module Presto.Core.LocalStorage where

import Prelude

import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)


foreign import getValueFromLocalStore' :: String -> Effect String
foreign import setValueToLocalStore' :: String -> String -> Effect Unit

getValueFromLocalStore :: String -> Aff (Maybe String)
getValueFromLocalStore k = let v = liftEffect $ getValueFromLocalStore' k
                               in ifM ((==) "__failed" <$> v) (pure Nothing) (Just <$> v)

setValueToLocalStore :: String -> String -> Aff Unit
setValueToLocalStore k v = liftEffect $ setValueToLocalStore' k v
