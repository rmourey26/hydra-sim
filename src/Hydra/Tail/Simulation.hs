{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLabels #-}

module Hydra.Tail.Simulation where

import Prelude

import Control.Exception
    ( Exception )
import Control.Monad
    ( foldM, forM, forM_, forever, liftM4, void, when )
import Control.Monad.Class.MonadAsync
    ( MonadAsync
    , async
    , concurrently_
    , forConcurrently_
    , replicateConcurrently_
    )
import Control.Monad.Class.MonadSTM
    ( MonadSTM
    , TMVar
    , TVar
    , atomically
    , modifyTVar
    , newTMVarIO
    , newTVarIO
    , readTVar
    )
import Control.Monad.Class.MonadThrow
    ( MonadThrow, throwIO )
import Control.Monad.Class.MonadTime
    ( MonadTime, Time (..) )
import Control.Monad.Class.MonadTimer
    ( MonadTimer, threadDelay )
import Control.Monad.IOSim
    ( IOSim, ThreadLabel, Trace (..), runSimTrace )
import Control.Monad.Trans.Class
    ( lift )
import Control.Monad.Trans.State.Strict
    ( StateT, evalStateT, execStateT, runStateT, state )
import Control.Tracer
    ( Tracer (..), contramap, traceWith )
import Data.Foldable
    ( traverse_ )
import Data.Functor
    ( ($>) )
import Data.Generics.Internal.VL.Lens
    ( view, (^.) )
import Data.Generics.Labels
    ()
import Data.List
    ( maximumBy )
import Data.Map.Strict
    ( Map, (!) )
import Data.Ratio
    ( (%) )
import Data.Text
    ( Text )
import Data.Time.Clock
    ( DiffTime, picosecondsToDiffTime, secondsToDiffTime )
import GHC.Generics
    ( Generic )
import Safe
    ( readMay )
import System.Random
    ( StdGen, mkStdGen, randomR )

import qualified Control.Monad.IOSim as IOSim
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

import Hydra.Tail.Simulation.MockTx
    ( MockTx (..), mockTx )
import Hydra.Tail.Simulation.Options
    ( ClientOptions (..)
    , NetworkCapacity (..)
    , PrepareOptions (..)
    , RunOptions (..)
    , ServerOptions (..)
    , kbitsPerSecond
    )
import Hydra.Tail.Simulation.PaymentWindow
    ( Balance (..)
    , Lovelace (..)
    , PaymentWindowStatus (..)
    , ada
    , initialBalance
    , modifyCurrent
    , newPaymentWindow
    )
import Hydra.Tail.Simulation.SlotNo
    ( SlotNo (..) )
import Hydra.Tail.Simulation.Utils
    ( foldTraceEvents
    , forEach
    , frequency
    , modifyM
    , updateF
    , withLabel
    , withTMVar
    , withTMVar_
    )
import HydraSim.Analyse
    ( diffTimeToSeconds )
import HydraSim.DelayedComp
    ( DelayedComp, delayedComp, runComp )
import HydraSim.Examples.Channels
    ( AWSCenters (..), channel )
import HydraSim.Multiplexer
    ( Multiplexer
    , getMessage
    , newMultiplexer
    , reenqueue
    , sendTo
    , startMultiplexer
    )
import HydraSim.Multiplexer.Trace
    ( TraceMultiplexer (..) )
import HydraSim.Sized
    ( Size (..), Sized (..) )
import HydraSim.Tx.Class
    ( Tx (..) )
import HydraSim.Types
    ( NodeId (..) )

import qualified HydraSim.Multiplexer as Multiplexer

--
-- Simulation
--

prepareSimulation :: MonadSTM m => PrepareOptions -> m [Event]
prepareSimulation PrepareOptions{clientOptions,numberOfClients,duration} = do
  let clientIds = [1..fromInteger numberOfClients]
  clients <- forM clientIds $ \clientId -> newClient clientId
  let getRecipients = mkGetRecipients clients
  let events = foldM
        (\st currentSlot -> (st <>) <$> forEach (stepClient clientOptions getRecipients currentSlot))
        mempty
        [ 0 .. pred duration ]
  evalStateT events (Map.fromList $ zip (view #identifier <$> clients) clients)

runSimulation :: RunOptions -> [Event] -> Trace ()
runSimulation opts@RunOptions{serverOptions} events = runSimTrace $ do
  let (serverId, clientIds) = (0, [1..fromInteger (getNumberOfClients events)])
  server <- newServer serverId clientIds serverOptions
  clients <- forM clientIds $ \clientId -> do
    client <- newClient clientId
    client <$ connectClient client server
  void $ async $ concurrently_
    (runServer trServer server)
    (forConcurrently_ clients (runClient trClient events serverId opts))
  threadDelay 1e99
 where
  tracer :: Tracer (IOSim a) TraceTailSimulation
  tracer = Tracer IOSim.traceM

  trClient :: Tracer (IOSim a) TraceClient
  trClient = contramap TraceClient tracer

  trServer :: Tracer (IOSim a) TraceServer
  trServer = contramap TraceServer tracer

data Analyze = Analyze
  { maxThroughput :: Double
    -- ^ Throughput as generated by clients
  , actualThroughput :: Double
    -- ^ Actual Throughput measured from confirmed transactions.
  , actualWriteNetworkUsage :: NetworkCapacity
    -- ^ Actual write network usage used / needed for running the simulation.
  , actualReadNetworkUsage :: NetworkCapacity
    -- ^ Actual read network usage used / needed for running the simulation.
  } deriving (Generic, Show)

data Metric
  = ConfirmedTxs
  | WriteUsage
  | ReadUsage
  deriving (Generic, Eq, Ord, Enum, Bounded)

analyzeSimulation :: forall m. Monad m => (SlotNo -> m ()) -> RunOptions -> [Event] -> Trace () -> m Analyze
analyzeSimulation notify RunOptions{slotLength} events trace = do
  (metrics, lastKnownTx, _) <-
    let zero :: Map Metric Integer
        zero = Map.fromList [ (k, 0) | k <- [minBound .. maxBound] ]

        fn :: (ThreadLabel, Time, TraceTailSimulation) -> (Map Metric Integer, DiffTime, SlotNo) -> m (Map Metric Integer, DiffTime, SlotNo)
        fn = \case
          (_threadLabel, Time t', TraceClient (TraceClientMultiplexer (MPRecvTrailing _nodeId AckTx{}))) ->
            (\(!m, !t, !sl) -> pure (Map.adjust (+ 1) ConfirmedTxs m, max t t', sl))

          (_threadLabel, _time, TraceServer (TraceServerMultiplexer (MPRecvLeading _nodeId (Size s)))) ->
            (\(!m, !t, !sl) -> pure (Map.adjust (+ toInteger s) ReadUsage m, t, sl))

          (_threadLabel, _time, TraceServer (TraceServerMultiplexer (MPSendLeading _nodeId (Size s)))) ->
            (\(!m, !t, !sl) -> pure (Map.adjust (+ toInteger s) WriteUsage m, t, sl))

          (_threadLabel, _time, TraceClient (TraceClientWakeUp sl')) ->
            (\(!m, !t, !sl) ->
              if sl' > sl then
                notify sl' $> (m, t, sl')
              else
                pure (m, t, sl))

          _ ->
            pure
     in foldTraceEvents fn (zero, 0, -1) trace

  let numberOfTransactions =
        fromIntegral (metrics ! ConfirmedTxs)

  pure $ Analyze
    { maxThroughput =
        numberOfTransactions / diffTimeToSeconds (durationOf events slotLength)
    , actualThroughput =
        numberOfTransactions / (1 + diffTimeToSeconds lastKnownTx)
    , actualWriteNetworkUsage =
        kbitsPerSecond $ (metrics ! WriteUsage) `div` 1024
    , actualReadNetworkUsage =
        kbitsPerSecond $ (metrics ! ReadUsage) `div` 1024
    }

--
-- (Simplified) Tail-Protocol
--

-- | Messages considered as part of the simplified Tail pre-protocol. We don't know exactly
-- what the Tail protocol hence we have a highly simplified view of it and reduce it to a
-- mere message broker between many producers and many consumers (the clients), linked together
-- via a single message broker (the server).
data Msg
  --
  -- ↓↓↓ Client messages ↓↓↓
  --
  = NewTx !MockTx ![ClientId]
  -- ^ A new transaction, sent to some peer. The current behavior of this simulation
  -- consider that each client is only sending to one single peer. Later, we probably
  -- want to challenge this assumption by analyzing real transaction patterns from the
  -- main chain and model this behavior.

  | Pull
  -- ^ Sent when waking up to catch up on messages received when offline.

  | Connect
  -- ^ Client connections and disconnections are modelled using 0-sized messages.

  | Disconnect
  -- ^ Client connections and disconnections are modelled using 0-sized messages.

  | SnapshotStart
  -- ^ Clients informing the server about an ongoing snapshot.

  | SnapshotEnd
  -- ^ Clients informing the server about the end of a snapshot

  --
  -- ↓↓↓ Server messages ↓↓↓
  --

  | NotifyTx !MockTx
  -- ^ The server will notify concerned clients with transactions they have subscribed to.
  -- How clients subscribe and how the server is keeping track of the subscription is currently
  -- out of scope and will be explored at a later stage.

  | AckTx !(TxRef MockTx)
  -- ^ The server replies to each client submitting a transaction with an acknowledgement.
  deriving (Generic, Show)

instance Sized Msg where
  size = \case
    NewTx tx clients ->
      sizeOfHeader + size tx + sizeOfAddress * fromIntegral (length clients)
    Pull ->
      sizeOfHeader
    Connect{} ->
      0
    Disconnect{} ->
      0
    SnapshotStart{} ->
      0
    SnapshotEnd{} ->
      0
    NotifyTx tx ->
      sizeOfHeader + size tx
    AckTx txId ->
      sizeOfHeader + size txId
   where
    sizeOfAddress = 57
    sizeOfHeader = 2

data TraceTailSimulation
  = TraceServer TraceServer
  | TraceClient TraceClient
  deriving (Show)

--
-- Server
--

type ServerId = NodeId

data Server m = Server
  { multiplexer :: Multiplexer m Msg
  , identifier  :: ServerId
  , region :: AWSCenters
  , options :: ServerOptions
  , registry :: TMVar m (Map ClientId (ClientState, [Msg], [Msg]))
  } deriving (Generic)

newServer
  :: MonadSTM m
  => ServerId
  -> [ClientId]
  -> ServerOptions
  -> m (Server m)
newServer identifier clientIds options@ServerOptions{region,writeCapacity,readCapacity} = do
  multiplexer <- newMultiplexer
    "server"
    outboundBufferSize
    inboundBufferSize
    (capacity writeCapacity)
    (capacity readCapacity)
  registry <- newTMVarIO clients
  return Server { multiplexer, identifier, region, options, registry }
 where
  outboundBufferSize = 1000000
  inboundBufferSize = 1000000
  clients = Map.fromList [ (clientId, (Offline, [], [])) | clientId <- clientIds ]

runServer
  :: forall m. (MonadAsync m, MonadTimer m, MonadThrow m)
  => Tracer m TraceServer
  -> Server m
  -> m ()
runServer tracer Server{multiplexer, options, registry} = do
  concurrently_
    (startMultiplexer (contramap TraceServerMultiplexer tracer) multiplexer)
    (replicateConcurrently_ (options ^. #concurrency) (withLabel "Main: Server" serverMain))
 where
  reenqueue' = reenqueue (contramap TraceServerMultiplexer tracer)

  serverMain :: m ()
  serverMain = do
    atomically (getMessage multiplexer) >>= \case
      (clientId, NewTx tx recipients) -> do
        void $ runComp (txValidate Set.empty tx)
        void $ runComp lookupClient

        blocked <- withTMVar registry $ \clients -> (,clients) <$>
          Map.traverseMaybeWithKey (matchBlocked recipients) clients

        -- Some of the recipients may be out of their payment window (i.e. 'Blocked'), if
        -- that's the case, we cannot process the transaction until they are done.
        if null blocked then
          withTMVar_ registry $ \clients -> do
            clients' <- flip execStateT clients $ do
              forM_ recipients $ \recipient -> do
                modifyM $ updateF clientId $ \case
                  (Online, mailbox, queue) -> do
                    Just (Online, mailbox, queue) <$ sendTo multiplexer recipient (NotifyTx tx)
                  (st, mailbox, queue) -> do
                    let msg = NotifyTx tx
                    traceWith tracer $ TraceServerStoreInMailbox clientId msg (length mailbox + 1)
                    pure $ Just (st, msg:mailbox, queue)
            sendTo multiplexer clientId (AckTx $ txRef tx)
            return clients'
        else
          withTMVar_ registry $ updateF clientId $ \(st, mailbox, queue) ->
            pure $ Just (st, mailbox, NewTx tx recipients:queue)
        serverMain

      (clientId, Pull) -> do
        runComp lookupClient
        withTMVar_ registry $ \clients -> do
          updateF clientId (\case
            (st, mailbox, queue) -> do
              mapM_ (sendTo multiplexer clientId) (reverse mailbox)
              pure $ Just (st, [], queue)
            ) clients
        serverMain

      (clientId, Connect) -> do
        runComp lookupClient
        withTMVar_ registry $ \clients -> do
          return $ Map.update (\(_, mailbox, queue) -> Just (Online, mailbox, queue)) clientId clients
        serverMain

      (clientId, Disconnect) -> do
        runComp lookupClient
        withTMVar_ registry $ \clients -> do
          return $ Map.update (\(_, mailbox, queue) -> Just (Offline, mailbox, queue)) clientId clients
        serverMain

      (clientId, SnapshotStart) -> do
        runComp lookupClient
        withTMVar_ registry $ \clients -> do
          return $ Map.update (\(_, mailbox, queue) -> Just (Blocked, mailbox, queue)) clientId clients
        serverMain

      (clientId, SnapshotEnd) -> do
        runComp lookupClient
        withTMVar_ registry $ updateF clientId $ \(_, mailbox, queue) -> do
          traverse_ (reenqueue' multiplexer) (reverse $ (clientId,) <$> queue)
          return $ Just (Offline, mailbox, [])
        serverMain

      (clientId, msg) ->
        throwIO (UnexpectedServerMsg clientId msg)

-- | A computation simulating the time needed to lookup a client in an in-memory registry.
-- The value is taken from running benchmarks of the 'containers' Haskell library on a
-- high-end laptop. The time needed to perform a lookup was deemed non negligeable in front of
-- the time needed to validate a transaction.
--
-- Note that a typical hashmap or map is implemented using balanced binary trees and provide a O(log(n))
-- lookup performances, so the cost of looking a client in a map of 1000 or 100000 clients is _roughly the same_.
lookupClient :: DelayedComp ()
lookupClient =
  delayedComp () (picosecondsToDiffTime 500*1e6) -- 500μs

-- | Return 'f (Just Blocked)' iif:
--
-- - A client is in the state 'Blocked'
-- - A client is in given input list of recipients
--
matchBlocked
  :: Applicative f
  => [ClientId]
  -> ClientId
  -> (ClientState, mailbox, blocked)
  -> f (Maybe ClientState)
matchBlocked recipients clientId = \case
  (Blocked, _, _) | clientId `elem` recipients ->
    pure (Just Blocked)
  _ ->
    pure Nothing

data TraceServer
  = TraceServerMultiplexer (TraceMultiplexer Msg)
  | TraceServerStoreInMailbox ClientId Msg Int
  deriving (Show)

data ServerMain = ServerMain deriving Show
instance Exception ServerMain

data UnexpectedServerMsg = UnexpectedServerMsg NodeId Msg
  deriving Show
instance Exception UnexpectedServerMsg

data UnknownClient = UnknownClient NodeId
  deriving Show
instance Exception UnknownClient

--
-- Client
--

type ClientId = NodeId

data ClientState = Online | Offline | Blocked
  deriving (Generic, Show, Eq)

data Client m = Client
  { multiplexer :: Multiplexer m Msg
  , identifier  :: ClientId
  , region :: AWSCenters
  , generator :: StdGen
  } deriving (Generic)

newClient :: MonadSTM m => ClientId -> m (Client m)
newClient identifier = do
  multiplexer <- newMultiplexer
    ("client-" <> show (getNodeId identifier))
    outboundBufferSize
    inboundBufferSize
    (capacity $ kbitsPerSecond 512)
    (capacity $ kbitsPerSecond 512)
  return Client { multiplexer, identifier, region, generator }
 where
  outboundBufferSize = 1000
  inboundBufferSize = 1000
  region = LondonAWS
  generator = mkStdGen (getNodeId identifier)

runClient
  :: forall m. (MonadAsync m, MonadTimer m, MonadThrow m)
  => Tracer m TraceClient
  -> [Event]
  -> ServerId
  -> RunOptions
  -> Client m
  -> m ()
runClient tracer events serverId opts Client{multiplexer, identifier} = do
  -- NOTE: We care little about how much each client balance is in practice. Although
  -- the 'Balance' is modelled as a product (initial, current) because of the intuitive
  -- view it offers, we are really only interested in the delta. Balances can therefore
  -- be _negative_ as part of the simulation.
  balance <- newTVarIO $ initialBalance 0
  concurrently_
    (startMultiplexer (contramap TraceClientMultiplexer tracer) multiplexer)
    (concurrently_
      (withLabel ("EventLoop: " <> show identifier) $ clientEventLoop (Offline, balance) 0 events)
      (withLabel ("Main: " <> show identifier) $ forever $ clientMain balance)
    )
 where
  paymentWindow :: Balance -> PaymentWindowStatus
  paymentWindow = case opts ^. #paymentWindow of
    Nothing -> const InPaymentWindow
    Just w  -> newPaymentWindow w

  clientMain :: TVar m Balance -> m ()
  clientMain balance =
    atomically (getMessage multiplexer) >>= \case
      (_, AckTx{}) ->
        pure ()
      (_, NotifyTx MockTx{txAmount}) ->
        -- NOTE: There's a slight _abuse_ here. Transactions are indeed written from the PoV
        -- of the _sender_. So the amount corresponds to how much did the sender "lost" in the
        -- transaction, but, there can be multiple recipients! Irrespective of this, we consider
        -- in the simulation that *each* recipient receives the full amount.
        atomically $ modifyTVar balance (modifyCurrent (+ txAmount))
      (nodeId, msg) ->
        throwIO $ UnexpectedClientMsg nodeId msg

  clientEventLoop :: (ClientState, TVar m Balance) -> SlotNo -> [Event] -> m ()
  clientEventLoop (!st, !balance) !currentSlot = \case
    [] ->
      pure ()

    (e:q) | from e /= identifier ->
      clientEventLoop (st, balance) currentSlot q

    (e@(Event _ _ (NewTx MockTx{txAmount} _)):q) | slot e <= currentSlot -> do
      atomically (paymentWindow <$> readTVar balance) >>= \case
        InPaymentWindow -> do
          sendTo multiplexer serverId (msg e)
          atomically $ modifyTVar balance (modifyCurrent (\x -> x - txAmount))
          clientEventLoop (Offline, balance) currentSlot q

        OutOfPaymentWindow -> do
          sendTo multiplexer serverId SnapshotStart
          threadDelay (secondsToDiffTime (unSlotNo (opts ^. #settlementDelay)) * opts ^. #slotLength)
          atomically $ modifyTVar balance (\Balance{current} -> initialBalance current)
          sendTo multiplexer serverId SnapshotEnd
          clientEventLoop (Offline, balance) (currentSlot + opts ^. #settlementDelay) (e:q)

    (e:q) | slot e <= currentSlot -> do
      when (st == Offline) $ do
        traceWith tracer (TraceClientWakeUp currentSlot)
        sendTo multiplexer serverId Connect
      sendTo multiplexer serverId (msg e)
      clientEventLoop (Online, balance) currentSlot q

    (e:q) -> do
      when (st == Online) $ sendTo multiplexer serverId Disconnect
      threadDelay (opts ^. #slotLength)
      clientEventLoop (Offline, balance) (currentSlot + 1) (e:q)

data UnexpectedClientMsg = UnexpectedClientMsg NodeId Msg
  deriving Show
instance Exception UnexpectedClientMsg

stepClient
  :: forall m. (Monad m)
  => ClientOptions
  -> (ClientId -> m [ClientId])
  -> SlotNo
  -> Client m
  -> m ([Event], Client m)
stepClient options getRecipients currentSlot client@Client{identifier, generator} = do
  (events, generator') <- runStateT step generator
  pure (events, client { generator = generator' })
 where
  step :: StateT StdGen m [Event]
  step = do
    pOnline <- state (randomR (1, 100))
    let online = pOnline % 100 <= options ^. #onlineLikelihood
    pSubmit <- state (randomR (1, 100))
    let submit = online && (pSubmit % 100 <= options ^. #submitLikelihood)
    recipients <- lift $ getRecipients identifier

    -- NOTE: The distribution is extrapolated from real mainchain data.
    amount <- fmap ada $ state $ frequency
      [ (122, randomR (1, 10))
      , (144, randomR (10, 100))
      , (143, randomR (100, 1000))
      , ( 92, randomR (1000, 10000))
      , ( 41, randomR (10000, 100000))
      , ( 12, randomR (100000, 1000000))
      ]

    -- NOTE: The distribution is extrapolated from real mainchain data.
    txSize <- fmap Size $ state $ frequency
      [ (318, randomR (192, 512))
      , (129, randomR (512, 1024))
      , (37, randomR (1024, 2048))
      , (12, randomR (2048, 4096))
      , (43, randomR (4096, 8192))
      , (17, randomR (8192, 16384))
      ]

    pure
      [ Event currentSlot identifier msg
      | (predicate, msg) <-
          [ ( online
            , Pull
            )
          , ( submit
            , NewTx (mockTx identifier currentSlot amount txSize) recipients
            )
          ]
      , predicate
      ]

data TraceClient
  = TraceClientMultiplexer (TraceMultiplexer Msg)
  | TraceClientWakeUp SlotNo
  deriving (Show)

--
-- Events
--

-- In this simulation, we have decoupled the generation of events from their
-- processing. 'Event's are used as an interface, serialized to CSV. This way,
-- the simulation can be fed with data coming from various places.
data Event = Event
  { slot :: !SlotNo
  , from :: !ClientId
  , msg :: !Msg
  } deriving (Generic, Show)

data SimulationSummary = SimulationSummary
  { numberOfClients :: !Integer
  , numberOfEvents :: !Integer
  , numberOfTransactions :: Integer
  , lastSlot :: !SlotNo
  } deriving (Generic, Show)

summarizeEvents :: [Event] -> SimulationSummary
summarizeEvents events = SimulationSummary
  { numberOfClients
  , numberOfEvents
  , numberOfTransactions
  , lastSlot
  }
 where
  numberOfEvents = toInteger $ length events
  numberOfClients = getNumberOfClients events
  numberOfTransactions = toInteger $ length [ e | e@(Event _ _ NewTx{}) <- events ]
  lastSlot = last events ^. #slot

durationOf :: [Event] -> DiffTime -> DiffTime
durationOf events slotLength =
  slotLength * fromIntegral (unSlotNo $ succ $ last events ^. #slot)

getNumberOfClients :: [Event] -> Integer
getNumberOfClients =
  toInteger . getNodeId . from . maximumBy (\a b -> getNodeId (from a) `compare` getNodeId (from b))

data CouldntParseCsv = CouldntParseCsv FilePath
  deriving Show
instance Exception CouldntParseCsv

writeEvents :: FilePath -> [Event] -> IO ()
writeEvents filepath events = do
  TIO.writeFile filepath $ T.unlines $
    "slot,clientId,event,size,amount,recipients"
    : (eventToCsv <$> events)

readEventsThrow :: FilePath -> IO [Event]
readEventsThrow filepath = do
  text <- TIO.readFile filepath
  case traverse eventFromCsv . drop 1 . T.lines $ text of
    Nothing -> throwIO $ CouldntParseCsv filepath
    Just events -> pure events

eventToCsv :: Event -> Text
eventToCsv = \case
  -- slot,clientId,'pull'
  Event (SlotNo sl) (NodeId cl) Pull ->
    T.intercalate ","
      [ T.pack (show sl)
      , T.pack (show cl)
      , "pull"
      ]

  -- slot,clientId,new-tx,size,amount,recipients
  Event (SlotNo sl) (NodeId cl) (NewTx (MockTx _ (Size sz) (Lovelace am)) rs) ->
    T.intercalate ","
      [ T.pack (show sl)
      , T.pack (show cl)
      , "new-tx"
      , T.pack (show sz)
      , T.pack (show am)
      , T.intercalate " " (T.pack . show . getNodeId <$> rs)
      ]

  e ->
    error $ "eventToCsv: invalid event to serialize: " <> show e

eventFromCsv :: Text -> Maybe Event
eventFromCsv line =
  case T.splitOn "," line of
    -- slot,clientId,'pull'
    (sl: (cl: ("pull": _))) -> Event
        <$> readSlotNo sl
        <*> readClientId cl
        <*> pure Pull

    -- slot,clientId,new-tx,size,amount,recipients
    [ sl, cl, "new-tx", sz, am, rs ] -> Event
        <$> readSlotNo sl
        <*> readClientId cl
        <*> (NewTx
          <$> liftM4 mockTx (readClientId cl) (readSlotNo sl) (readAmount am) (readSize sz)
          <*> readRecipients rs
        )


    _ ->
      Nothing
 where
  readClientId :: Text -> Maybe ClientId
  readClientId =
    fmap NodeId . readMay . T.unpack

  readSlotNo :: Text -> Maybe SlotNo
  readSlotNo =
    fmap SlotNo . readMay . T.unpack

  readAmount :: Text -> Maybe Lovelace
  readAmount =
    readMay . T.unpack

  readSize :: Text -> Maybe Size
  readSize =
    fmap Size . readMay . T.unpack

  readRecipients :: Text -> Maybe [ClientId]
  readRecipients = \case
    "" -> Just []
    ssv -> traverse readClientId (T.splitOn " " ssv)

--
-- Helpers
--

getRegion
  :: [AWSCenters]
  -> NodeId
  -> AWSCenters
getRegion regions (NodeId i) =
  regions !! (i `mod` length regions)

connectClient
  :: (MonadAsync m, MonadTimer m, MonadTime m)
  => Client m
  -> Server m -> m ()
connectClient client server =
  Multiplexer.connect
    ( channel (client ^. #region) (server ^. #region) )
    ( client ^. #identifier, client ^. #multiplexer )
    ( server ^. #identifier, server ^. #multiplexer )

-- Simple strategy for now to get recipients of a particular client;
-- at the moment, the next client in line is considered a recipient.
mkGetRecipients
  :: Applicative m
  => [Client m]
  -> ClientId
  -> m [ClientId]
mkGetRecipients clients (NodeId sender) = do
  let recipient = NodeId $ max 1 (succ sender `mod` (length clients + 1))
  pure [recipient]
