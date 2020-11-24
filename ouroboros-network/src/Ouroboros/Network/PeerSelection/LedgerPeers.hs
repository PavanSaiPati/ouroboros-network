{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Ouroboros.Network.PeerSelection.LedgerPeers (
    DomainAddress (..),
    LedgerPeersConsensusInterface (..),
    RelayAddress (..),
    PoolStake,
    runLedgerPeers,
    TraceLedgerPeers (..),
    pickPeers,
    ackPoolStake,
    addPeerMetric,
    initPeerMetric,
    PeerMetric,

    Socket.PortNumber
    ) where


import           Control.Monad.Class.MonadAsync
import           Control.Monad.Class.MonadSTM.Strict
import           Control.Monad.Class.MonadTime
import           Control.Monad.Class.MonadTimer
import           Control.Tracer (Tracer, traceWith)
import qualified Data.IP as IP
import           Data.List (foldl', nub)
import           Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import           Data.Maybe (isNothing, fromJust)
import qualified Data.Map.Strict as Map
import           Data.Map.Strict (Map)
import           Data.Ratio
import           Data.Time.Clock (diffUTCTime)
import           Data.Word
import qualified Network.Socket as Socket
import           Network.Socket (SockAddr)
import           System.Random

import           Cardano.Slotting.Slot (SlotNo (..))
import           Ouroboros.Network.ConnectionId
import           Ouroboros.Network.PeerSelection.RootPeersDNS (DomainAddress (..))
import           Ouroboros.Network.Subscription.Ip
import           Ouroboros.Network.Subscription.Dns

import           Text.Printf

data LedgerPeersConsensusInterface m a = LedgerPeersConsensusInterface {
      lpGetPeers :: (SlotNo -> STM m (SlotNo, [(PoolStake, NonEmpty RelayAddress)]))
    }

data TraceLedgerPeers =
      PickedPeer !RelayAddress !AckPoolStake ! PoolStake
    | PickedPeers !Word16 ![RelayAddress]
    | FetchingNewLedgerState !SlotNo !Int
    | LedgerPeersXXX !String

type PeerMetric m a = StrictTVar m (Map a (Map SlotNo DiffTime))

initPeerMetric :: MonadSTM m => m (PeerMetric m a)
initPeerMetric = newTVarIO Map.empty

addPeerMetric :: forall m a.
       ( MonadSTM m
       , Ord a
       )
    => PeerMetric m a
    -> ConnectionId a
    -> SlotNo
    -> DiffTime
    -> STM m ()
addPeerMetric db conId slotNo dTime = do
    readTVar db >>= Map.alterF fn (remoteAddress conId) >>= writeTVar db
  where
    fn :: Maybe (Map SlotNo DiffTime) -> STM m (Maybe (Map SlotNo DiffTime))
    fn Nothing = return $ Just $ Map.singleton slotNo dTime
    fn (Just pm) = return $ Just $ Map.insert slotNo dTime pm


instance Show TraceLedgerPeers where
    show (PickedPeer addr ackStake stake) =
        printf "PickedPeer %s ack stake %s ( %.04f) relative stake %s ( %.04f )"
            (show addr)
            (show ackStake) (fromRational ackStake :: Double)
            (show stake) (fromRational stake :: Double)
    show (PickedPeers n peers) =
        printf "PickedPeers %d %s" n (show peers)
    show (FetchingNewLedgerState tip cnt) =
        printf "Fetching new ledgerstate at slot %s , %d registered pools"
            (show tip)
            cnt
    show (LedgerPeersXXX msg) = msg


data RelayAddress = RelayAddressDomain DomainAddress
                  | RelayAddressAddr IP.IP Socket.PortNumber
                  deriving (Show, Eq, Ord)

-- | The relative stake of the stakepool. A value in the [0, 1] range.
type PoolStake = Rational

-- | The relative stake of the stakepool and all preceeding pools. A value in the range [0, 1].
type AckPoolStake = Rational

-- | Convert a list of pools with stake to a Map keyed on the ackumulated stake.
-- 
ackPoolStake :: [(PoolStake, NonEmpty RelayAddress)]
             -> Map Rational (PoolStake, NonEmpty RelayAddress)
ackPoolStake pl =
    let pl' = reRelativeStake pl
        ackList = snd $ foldl' (\(as, ps) (s, rs) -> (as + s, (as + s, (s, rs)):ps)) (0, []) pl' in
    Map.fromList ackList

-- | Not all stake pools have valid/usable relay information. This means that we need to
-- recalculate the relative stake for each pool.
reRelativeStake :: [(PoolStake, NonEmpty RelayAddress)]
                -> [(PoolStake, NonEmpty RelayAddress)]
reRelativeStake pl =
    let total = sum $ map fst pl in
    map (\(s, rls) -> (s / total, rls)) pl

-- try to pick n random peers
pickPeers :: forall m. Monad m
          => StdGen
          -> Tracer m TraceLedgerPeers
          -> Map Rational (PoolStake, NonEmpty RelayAddress)
          -> Word16
          -> m (StdGen, [RelayAddress])
pickPeers inRng _ pools _ | Map.null pools = return (inRng, []) 
pickPeers inRng tracer pools cnt = go inRng cnt []
  where
    go :: StdGen -> Word16 -> [RelayAddress] -> m (StdGen, [RelayAddress])
    go rng 0 picked = return (rng, picked)
    go rng n picked =
        let (r :: Word64, rng') = random rng
            d = maxBound :: Word64
            x = fromIntegral r % fromIntegral d
            !pick_m = Map.lookupGE x pools in
        case pick_m of
             Nothing -> go rng' (n - 1) picked -- XXX We failed pick a peer. Shouldn't this be an error?
             Just (ackStake, (stake, relays)) -> do
                 let (ix, rng'') = randomR (0, NonEmpty.length relays - 1) rng'
                     relay = relays NonEmpty.!! ix
                 traceWith tracer $ PickedPeer relay ackStake stake
                 go rng'' (n - 1) (relay : picked)


pickWorstPeer :: forall m.
       MonadSTM m
    => PeerMetric m SockAddr
    -> SlotNo
    -> STM m (Map SlotNo (DiffTime, SockAddr))
pickWorstPeer pmVar minSlotNo = do
    pm <- readTVar pmVar

    -- First remove all samples older than minSlotNo
    let pm' = Map.map minFn pm

    return (Map.foldlWithKey' foldByPeer Map.empty pm')
  where
    minFn :: Map SlotNo DiffTime -> Map SlotNo DiffTime
    minFn pms = Map.filterWithKey (\k _ -> k >= minSlotNo) pms

    foldByPeer :: Map SlotNo (DiffTime, SockAddr)
               -> SockAddr
               -> Map SlotNo DiffTime
               -> Map SlotNo (DiffTime, SockAddr)
    foldByPeer bestSlotM peer peerMetric = Map.foldlWithKey' foldBySlot bestSlotM peerMetric
      where
        foldBySlot :: Map SlotNo (DiffTime, SockAddr)
                   -> SlotNo
                   -> DiffTime
                   -> Map SlotNo (DiffTime, SockAddr)
        foldBySlot bestSlotM' slotNo dTime =
            case Map.lookup slotNo bestSlotM of
                 Nothing -> Map.insert slotNo (dTime, peer) bestSlotM'
                 Just (oldTime, _) -> if dTime < oldTime
                                    then Map.insert slotNo (dTime, peer) bestSlotM'
                                    else bestSlotM'



runLedgerPeers :: forall m.
                      ( MonadAsync m
                      , MonadDelay m
                      , MonadTime m
                      )
               => StdGen
               -> Tracer m TraceLedgerPeers
               -> LedgerPeersConsensusInterface m SockAddr
               -> PeerMetric m SockAddr
               -> (IPSubscriptionTarget -> m ())
               -> (DnsSubscriptionTarget -> m ())
               -> m ()
runLedgerPeers inRng tracer LedgerPeersConsensusInterface{..} peerMetric runIP runDns =
    go inRng Nothing Map.empty
  where

    go rng oldTs_m peerMap = do
        let peerListLifeTime = if Map.null peerMap then 30
                                                   else 200 -- XXX moar
            useLedgerAfter = 4492800 + 2*21600 -- XXX two epochs after shelley hard fork
        !now <- getMonotonicTime
        (!peerMap', ts_m) <-
            if isNothing oldTs_m || diffTime now (fromJust oldTs_m) > peerListLifeTime
               then do
                   (tip, plx) <- atomically $ lpGetPeers useLedgerAfter
                   let pl = ackPoolStake plx
                   !now' <- getMonotonicTime
                   traceWith tracer $ FetchingNewLedgerState tip $ Map.size pl
                   return (pl, Just now')
               else return (peerMap, oldTs_m)

        (rng', !pickedPeers) <- pickPeers rng tracer peerMap' 8
        traceWith tracer $ PickedPeers 8 pickedPeers
        let (ipTarget, dnsTargets) = foldl' peersToSubTarget
                                                 (IPSubscriptionTarget [] 0 , []) $ nub pickedPeers
        ipAid <- async $ runIP ipTarget

        dnsAids <- sequence [async $ runDns peer | peer <- dnsTargets]

        -- XXX let it run for 3 minutes, then repeat with a new set of random peers.
        ttlAid <- async (threadDelay 180)

        wait ttlAid
        currentSlot <- getCurrentSlotNo
        pm <- atomically $ pickWorstPeer peerMetric (currentSlot - 1000)
        traceWith tracer $ LedgerPeersXXX $ dumpMinPeers pm

        _ <- waitAnyCancel (ttlAid : ipAid : dnsAids)
        go rng' ts_m peerMap'

    peersToSubTarget :: (IPSubscriptionTarget, [DnsSubscriptionTarget])
          -> RelayAddress
          -> (IPSubscriptionTarget, [DnsSubscriptionTarget])
    peersToSubTarget (ipSub, dnsSubs) (RelayAddressAddr addr port) =
        ( ipSub { ispIps = IP.toSockAddr (addr, port) : ispIps ipSub
               , ispValency = 1 + ispValency ipSub
               }
        , dnsSubs
        )
    peersToSubTarget (ipSub, dnsSubs) (RelayAddressDomain domain) =
        let dnsTarget = DnsSubscriptionTarget {
                              dstDomain  = daDomain domain
                            , dstPort    = daPortNumber domain
                            , dstValency = 1
                            } in
        ( ipSub
        , dnsTarget : dnsSubs
        )

    getCurrentSlotNo :: m SlotNo
    getCurrentSlotNo = do
        now <- getCurrentTime
        let firstShelleySlot = 4492800
            shelleyStart = read "2020-07-29 21:44:51 UTC" :: UTCTime
            x = realToFrac $ diffUTCTime now shelleyStart :: Double

        return $ SlotNo $ firstShelleySlot + (round x)

    dumpMinPeers :: Map SlotNo (DiffTime, SockAddr) -> String
    dumpMinPeers m =
        let l = Map.toList m in
        concatMap (\(k, (dTime, peer)) -> printf "XXY%d,%s,%s"
            (unSlotNo k) (show dTime) (show peer)) l
