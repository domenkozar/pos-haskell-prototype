{-# LANGUAGE TemplateHaskell #-}
module Pos.Ssc.GodTossing.LocalData.Types
       (
         dsLocalCommitments
       , dsGlobalCommitments
       , dsLocalShares
       ) where

import           Pos.Ssc.GodTossing.Types.Base (CommitmentsMap, OpeningsMap, SharesMap,
                                                VssCertificatesMap)
import           Control.Lens                  (makeLenses)

data GtLocalData = GtLocalData
    { -- | Local set of 'Commitment's. These are valid commitments which are
      -- known to the node and not stored in blockchain. It is useful only
      -- for the first 'k' slots, after that it should be discarded.
      _dsLocalCommitments   :: !CommitmentsMap
    , -- | Local set of openings
      _dsLocalOpenings      :: !OpeningsMap
    , -- | Local set of decrypted shares (encrypted shares are stored in
      -- commitments).
      _dsLocalShares        :: !SharesMap
    , -- | Local set of VSS certificates
      _dsLocalCertificates  :: !VssCertificatesMap
    }

makeLenses ''GtLocalData
