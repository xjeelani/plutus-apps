{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NamedFieldPuns     #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Plutus.ChainIndex.Config(
  ChainIndexConfig(..),
  DecodeConfigException(..),
  defaultConfig,
  -- * Lenses
  socketPath,
  dbPath,
  port,
  networkId,
  securityParam,
  slotConfig
  ) where

import Cardano.Api (NetworkId (..))
import Control.Exception (Exception)
import Control.Lens (makeLensesFor)
import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)
import Ledger.TimeSlot (SlotConfig (..))
import Ouroboros.Network.Magic (NetworkMagic (..))
import Prettyprinter (Pretty (..), viaShow, vsep, (<+>))

data ChainIndexConfig = ChainIndexConfig
  { cicSocketPath    :: String
  , cicDbPath        :: String
  , cicPort          :: Int
  , cicNetworkId     :: NetworkId
  , cicSecurityParam :: Int -- ^ The number of blocks after which a transaction cannot be rolled back anymore
  , cicSlotConfig    :: SlotConfig
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | For some reason these are not defined anywhere, and these are the
--   reason for the -Wno-orphans option.
deriving stock instance Generic NetworkId
deriving anyclass instance FromJSON NetworkId
deriving anyclass instance ToJSON NetworkId
deriving anyclass instance FromJSON NetworkMagic
deriving anyclass instance ToJSON NetworkMagic

-- | These settings work with the Alonzo Purple testnet
defaultConfig :: ChainIndexConfig
defaultConfig = ChainIndexConfig
  { cicSocketPath = "/tmp/node-server.sock"
  , cicDbPath     = "/tmp/chain-index.db"
  , cicPort       = 9083
  , cicNetworkId  = Testnet $ NetworkMagic 8
  , cicSecurityParam = 2160
  , cicSlotConfig =
      SlotConfig
        { scSlotZeroTime = 1591566291000
        , scSlotLength   = 1000
        }
  }

instance Pretty ChainIndexConfig where
  pretty ChainIndexConfig{cicSocketPath, cicDbPath, cicPort, cicNetworkId, cicSecurityParam} =
    vsep [ "Socket:" <+> pretty cicSocketPath
         , "Db:" <+> pretty cicDbPath
         , "Port:" <+> pretty cicPort
         , "Network Id:" <+> viaShow cicNetworkId
         , "Security Param:" <+> pretty cicSecurityParam
         ]

makeLensesFor [
  ("cicSocketPath", "socketPath"),
  ("cicDbPath", "dbPath"),
  ("cicPort", "port"),
  ("cicNetworkId", "networkId"),
  ("cicSecurityParam", "securityParam"),
  ("cicSlotConfig", "slotConfig")
  ] 'ChainIndexConfig

newtype DecodeConfigException = DecodeConfigException String
  deriving stock Show
  deriving anyclass Exception
