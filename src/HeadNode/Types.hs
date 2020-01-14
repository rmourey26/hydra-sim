module HeadNode.Types where

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set

import Control.Monad.Class.MonadAsync
import Control.Monad.Class.MonadSTM

import Channel
import DelayedComp
import MSig.Mock
import Tx.Class

-- | Identifiers for nodes in the head protocol.
newtype NodeId = NodeId Int
  deriving (Show, Ord, Eq)

-- | Local transaction objects
data Tx tx => TxO tx = TxO
  { txoIssuer :: NodeId,
    txoTx :: tx,
    txoT :: Set (TxRef tx),
    txoS :: Set Sig,
    txoSigma :: Maybe ASig
  } deriving (Eq, Ord, Show)

-- | Snapshot Sequence Number
newtype SnapN = SnapN Int
  deriving (Eq, Show)

nextSn :: SnapN -> SnapN
nextSn (SnapN n) = SnapN (n + 1)

-- | Snapshot objects
data Tx tx => Snap tx = Snap {
  snos :: SnapN,
  snoO :: Set (TxInput tx),
  snoT :: Set (TxRef tx),
  snoS :: Set Sig,
  snoSigma :: Maybe ASig
  } deriving (Eq, Show)

emptySnap :: Tx tx => Snap tx
emptySnap = Snap {
  snos = SnapN (-1),
  snoO = Set.empty,
  snoT = Set.empty,
  snoS = Set.empty,
  snoSigma = Nothing
  }

data TxSendStrategy tx =
    SendNoTx
  | SendSingleTx tx
  deriving (Show, Eq)

-- Multi-sig functionality for a given node.
data Tx tx => MS tx = MS {
  ms_sig_tx :: SKey -> tx -> DelayedComp Sig,
  ms_asig_tx :: tx -> Set VKey -> Set Sig -> DelayedComp ASig,
  ms_verify_tx :: AVKey -> tx -> ASig -> DelayedComp Bool,

  ms_sig_sn :: SKey -> (SnapN, Set (TxInput tx)) -> DelayedComp Sig,
  ms_asig_sn :: (SnapN, Set (TxInput tx)) -> Set VKey -> Set Sig -> DelayedComp ASig,
  ms_verify_sn :: AVKey -> (SnapN, Set (TxInput tx)) -> ASig -> DelayedComp Bool
  }

data Tx tx => NodeConf tx = NodeConf {
  hcNodeId :: NodeId,
  hcTxSendStrategy :: TxSendStrategy tx,
  hcMSig :: MS tx,
  -- | Determine who is responsible to create which snapshot.
  hcLeaderFun :: SnapN -> NodeId
  }

data Tx tx => HeadNode m tx = HeadNode {
  hnConf :: NodeConf tx,
  hnState :: TMVar m (HState m tx),
  hnInbox :: TBQueue m (NodeId, HeadProtocol tx),
  hnPeerHandlers :: TVar m (Map NodeId (Async m ()))
  }

data Tx tx => HState m tx = HState {
  hsPartyIndex :: Int,
  hsSK :: SKey,
  -- | Verification keys of all nodes (including this one)
  hsVKs :: Set VKey,
  -- | Channels for communication with peers.
  hsChannels :: (Map NodeId (Channel m (HeadProtocol tx))),
  -- | Latest signed snapshot number
  hsSnapNSig :: SnapN,
  -- | Latest confirmed snapshot number
  hsSnapNConf :: SnapN,
  -- | UTxO set signed by this node
  hsUTxOSig :: Set (TxInput tx),
  -- | Confirmed UTxO set
  hsUTxOConf :: Set (TxInput tx),
  -- | Latest signed snapshot
  hsSnapSig :: Snap tx,
  -- | Latest confirmed snapshot
  hsSnapConf :: Snap tx,
  -- | Set of txs signed by this node
  hsTxsSig :: Map (TxRef tx) (TxO tx),
  -- | Set of confirmed txs
  hsTxsConf :: Map (TxRef tx) (TxO tx)
  }

hnStateEmpty :: Tx tx => NodeId -> HState m tx
hnStateEmpty (NodeId i)= HState {
  hsPartyIndex = i,
  hsSK = SKey i,
  hsVKs = Set.singleton $ VKey i,
  hsChannels = Map.empty,
  hsSnapNSig = SnapN (-1),
  hsSnapNConf = SnapN (-1),
  hsUTxOSig = Set.empty,
  hsUTxOConf = Set.empty,
  hsSnapSig = emptySnap,
  hsSnapConf = emptySnap,
  hsTxsSig = Map.empty,
  hsTxsConf = Map.empty
  }

-- Protocol Stuff

-- | Events in the head protocol.
--
-- This includes messages that are exchanged between nodes, as well as local
-- client messages.
--
-- Corresponds to Fig 6 in the Hydra paper.
data Tx tx => HeadProtocol tx =
  -- messages from client

  -- | Submit a new transaction to the network
    New tx
  -- | Submit a new snapshot
  | NewSn

  -- inter-node messages

  -- | Request to send a signature for a transaction to a given node
  | SigReqTx tx
  -- | Response to a signature request.
  | SigAckTx (TxRef tx) Sig
  -- | Show a Tx with a multi-sig of every participant.
  | SigConfTx (TxRef tx) ASig

  -- | Request signature for a snapshot.
  | SigReqSn SnapN (Set (TxRef tx))
  -- | Provide signature for a snapshot.
  | SigAckSn SnapN Sig
  -- | Provide an aggregate signature for a confirmed snapshot.
  | SigConfSn SnapN ASig
  deriving (Show, Eq)

-- | Decision of the node what to do in response to an event.
data Decision m tx =
  -- | The event is invalid. Since the check might take some time, this involves
  -- a 'DelayedComp'.
    DecInvalid (DelayedComp ()) String
  -- | The event cannot be applied yet, but we should put it back in the queue.
  -- Again, this decision might have required some time, which we can encode via
  -- a 'DelayedComp'.
  | DecWait (DelayedComp ())
  -- | The event can be applied, yielding a new state. Optionally, this might
  -- cause messages to be sent to one or all nodes.
  | DecApply {
      -- | Updated state of the node.
      --
      -- The 'DelayedComp' should include both the time taken to compute the new
      -- state, and also any time used for validation checks.
      decisionState :: DelayedComp (HState m tx),
      -- | Trace of the decision
      decisionTrace :: TraceProtocolEvent tx,
      -- | I addition to updating the local state, some events also trigger
      -- sending further messages to one or all nodes.
      --
      -- This is a 'DelayedComp', since preparing the message might require time.
      decisionMessage :: DelayedComp (SendMessage tx)
      }

-- | Events may trigger sending or broadcasting additional messages.
data SendMessage tx =
    SendNothing
  | SendTo NodeId (HeadProtocol tx)
  | Multicast (HeadProtocol tx)
  deriving Show

-- | A function that encodes a response to an event
--
-- It takes a state and a message, and produces a 'Decision'
type HStateTransformer m tx = HState m tx -> HeadProtocol tx -> Decision m tx

-- | Traces in the simulation
data TraceHydraEvent tx =
    HydraMessage (TraceMessagingEvent tx)
  | HydraProtocol (TraceProtocolEvent tx)
  deriving (Eq, Show)

-- | Tracing messages that are sent/received between nodes.
data TraceMessagingEvent tx =
    TraceMessageSent NodeId (HeadProtocol tx)
  | TraceMessageMulticast (HeadProtocol tx)
  | TraceMessageClient (HeadProtocol tx)
  | TraceMessageReceived NodeId (HeadProtocol tx)
  | TraceMessageRequeued (HeadProtocol tx)
  deriving (Eq, Show)

-- | Tracing how the node state changes as transactions are acknowledged, and
-- snapshots are produced.
data Tx tx => TraceProtocolEvent tx =
  -- | A new transaction has been submitted by a node.
    TPTxNew (TxRef tx) NodeId
  -- | A transaction is being signed by a node.
  | TPTxSig (TxRef tx) NodeId
  -- | A tx signature from a node has been received.
  | TPTxAck (TxRef tx) NodeId
  -- | A transaction has become confirmed (i.e., acknowledged by all the nodes).
  | TPTxConf (TxRef tx)

  -- | A new snapshot has been submitted by a node.
  | TPSnNew SnapN NodeId
  -- | Snapshot is being signed by a node.
  | TPSnSig SnapN NodeId
  -- | Snapshot signature has been received from a node.
  | TPSnAck SnapN NodeId
  -- | Snapshot is confirmed.
  | TPSnConf SnapN

  -- | We tried a transition that failed to alter the state.
  | TPInvalidTransition String
  -- | Transition was valid, but had no effect
  | TPNoOp String
  deriving (Eq, Show)
