{-# LANGUAGE AllowAmbiguousTypes    #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE Rank2Types             #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE TupleSections          #-}
{-# LANGUAGE TypeFamilies           #-}

-- | GodTossing storage.

module Pos.Ssc.GodTossing.Storage.Types
       ( GtStorage (..)
       , GtStorageVersion (..)

       -- * Lenses
       -- ** GtStorage
       , dsVersionedL
       , dsLastProcessedSlotL
       -- ** GtStorageVersion
       , dsGlobalCommitments
       , dsGlobalShares
       , dsGlobalOpenings
       , dsGlobalCertificates
       ) where

import           Control.Lens                  (makeLenses, makeLensesFor)
import           Data.Default                  (Default (..))
import           Data.List.NonEmpty            (NonEmpty (..))
import           Data.List.NonEmpty            (NonEmpty ((:|)))
import           Data.SafeCopy                 (base, deriveSafeCopySimple)
import           Universum

import           Pos.Ssc.GodTossing.Genesis    (genesisCertificates)
import           Pos.Ssc.GodTossing.Types.Base (CommitmentsMap, OpeningsMap, SharesMap,
                                                VssCertificatesMap)
import           Pos.Types                     (SlotId, unflattenSlotId)

data GtStorageVersion = GtStorageVersion
     {
      -- | Set of 'Commitment's stored in blocks for current epoch. This can
      -- be calculated by 'mconcat'ing stored commitments, but it would be
      -- inefficient to do it every time we need to know if commitments is
      -- stored in blocks.
      _dsGlobalCommitments  :: !CommitmentsMap
    , -- | Openings stored in blocks
      _dsGlobalOpenings     :: !OpeningsMap
    , -- | Decrypted shares stored in blocks. These shares are guaranteed to
      -- match encrypted shares stored in 'dsGlobalCommitments'.
      _dsGlobalShares       :: !SharesMap
    , -- | VSS certificates stored in blocks (for all time, not just for
      -- current epoch)
      _dsGlobalCertificates :: !VssCertificatesMap
    } deriving Show

makeLenses ''GtStorageVersion
deriveSafeCopySimple 0 'base ''GtStorageVersion

instance Default GtStorageVersion where
    def =
        GtStorageVersion
        { _dsGlobalCommitments = mempty
        , _dsGlobalOpenings = mempty
        , _dsGlobalShares = mempty
        , _dsGlobalCertificates = genesisCertificates
        }

data GtStorage = GtStorage
    { -- | Last several versions of MPC storage, a version for each received
      -- block. To bring storage to the state as it was just before the last
      -- block arrived, just remove the head. All incoming commitments/etc
      -- which aren't parts of blocks are applied to the head, too.
      --
      -- TODO: this is a very naive solution. A better one would be storing
      -- deltas for maps which are in 'GtStorageVersion', see [POS-25] for
      -- the explanation of deltas.
      _dsVersioned         :: NonEmpty GtStorageVersion
    , -- | Last slot we are aware of.
      _dsLastProcessedSlot :: !SlotId
    }

flip makeLensesFor ''GtStorage
    [ ("_dsVersioned", "dsVersionedL")
    , ("_dsLastProcessedSlot", "dsLastProcessedSlotL")
    ]
deriveSafeCopySimple 0 'base ''GtStorage

instance Default GtStorage where
    def =
        GtStorage
        { _dsVersioned = (def :| [])
        , _dsLastProcessedSlot = unflattenSlotId 0
        }
