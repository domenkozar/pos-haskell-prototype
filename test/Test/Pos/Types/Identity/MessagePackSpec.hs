
-- | This module tests MessagePack instances.

module Test.Pos.Types.Identity.MessagePackSpec
       ( spec
       ) where

import           Test.Hspec            (Spec, describe)
import           Test.Hspec.QuickCheck (prop)
import           Universum

import qualified Pos.Types             as T

import           Test.Pos.Util         (msgPackEncodeDecode)

spec :: Spec
spec = describe "Types" $ do
    describe "MessagePack instances" $ do
        prop "Epochindex" (msgPackEncodeDecode @T.EpochIndex)
        prop "Localslotindex" (msgPackEncodeDecode @T.LocalSlotIndex)
        prop "SlotId" (msgPackEncodeDecode @T.SlotId)
        prop "Coin" (msgPackEncodeDecode @T.Coin)
        prop "Address" (msgPackEncodeDecode @T.Address)
        prop "TxIn" (msgPackEncodeDecode @T.TxIn)
        prop "TxOut" (msgPackEncodeDecode @T.TxOut)
        prop "Tx" (msgPackEncodeDecode @T.Tx)
        prop "SharedSeed" (msgPackEncodeDecode @T.SharedSeed)
        prop "Chaindifficulty" (msgPackEncodeDecode @T.ChainDifficulty)
