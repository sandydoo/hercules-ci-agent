{-# LANGUAGE DeriveAnyClass #-}

module Hercules.API.GitLab.PatchInstallationBuilder where

import Hercules.API.Prelude

data PatchInstallationBuilder = PatchInstallationBuilder
  { name :: Maybe Text,
    displayName :: Maybe Text
  }
  deriving (Generic, Show, Eq, NFData, ToJSON, FromJSON, ToSchema)
