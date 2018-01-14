module Tucker.Error where

import Control.Exception

newtype TCKRError = TCKRError String deriving (Eq)

instance Show TCKRError where
    show (TCKRError err) = "tucker error: " ++ err

instance Exception TCKRError