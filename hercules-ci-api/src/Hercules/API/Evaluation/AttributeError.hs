{-# LANGUAGE DeriveAnyClass #-}

module Hercules.API.Evaluation.AttributeError where

import Hercules.API.Prelude

data AttributeError = AttributeError
  { errorMessage :: Text,
    -- | Not intended to be displayed to the user. This is
    --   @Just "BuildException"@ for evaluation time build failures.
    errorType :: Maybe Text,
    errorDerivation :: Maybe Text,
    trace :: Maybe Text
  }
  deriving (Generic, Show, Eq, NFData, ToJSON, FromJSON, ToSchema)
