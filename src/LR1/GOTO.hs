module LR1.GOTO where
import LR1.Fixpoint (Map, one, Get ((?)), set)
import qualified LR1.State as State
import qualified LR1.Grammar as Grammar
import qualified LR1.FIRST as FIRST
import Control.Lens hiding (set, index)
import qualified Data.Map.Monoidal as Map
import Control.Monad (foldM)
import qualified Data.Set as Set
import qualified LR1.Item as Item
import qualified LR1.Point as Point
import Data.Set (Set)

import Data.Traversable (for)
import Data.Function (on)
import Data.Maybe (mapMaybe, fromJust)
import Data.List (groupBy, sortBy)
import GHC.Generics (Generic)
import Data.Text (Text)
import qualified Data.Text as Text

newtype T = GOTO
  { unwrap :: Map State.Index (Map Point.T State.Index)
  }
  deriving stock (Show, Generic)

instance Get LR1.GOTO.T (State.Index, Point.T) State.Index where
  GOTO m ? (i, t) = m Map.! i Map.! t

make :: forall m. State.HasReg m => Grammar.T -> FIRST.T -> m LR1.GOTO.T
make grammar first = do
  state0 <- State.firstState grammar first
  loop (one state0) (GOTO Map.empty)
  where
    -- Add states to the state registry until no new states can be found.
    loop :: Set State.Index -> LR1.GOTO.T -> m LR1.GOTO.T
    loop pool goto = do
      (pool', goto') <- foldM add (Set.empty, goto) pool
      if Set.null pool'
      then return goto'
      else loop pool' goto'

    -- Given a state, register it in registry and all its transitions in GOTO.
    add :: (Set State.Index, LR1.GOTO.T) -> State.Index -> m (Set State.Index, LR1.GOTO.T)
    add (pool, GOTO goto) index = do
      -- Add the state to goto.
      -- Unless there's empty (Point -> State.Index) map, we can't add stuff later.
      let
        goto'
          | Map.member index goto = goto
          | otherwise             = goto & at index ?~ Map.empty

      materialized <- uses State.indices (Map.! index)

      let
        -- Group all items in the state by the entity at the locus
        -- (entity said item must accept to proceed)
        itemsByNextPoint =
          materialized
            & State.items               -- get Item set
            & Set.toList                -- get Item list
            & mapMaybe Item.uncons      -- select (Locus, Next) from non-reducing Items
            & sortBy (on compare fst)   -- groupBy can only work with sorted ._.
            & groupBy (on (==) fst)     -- group into (Locus, Next)
                                        -- v-- turn [(Locus, Next)] into (Locus, [Next])
            & fmap do \pairs@((point, _) : _) -> (point, set (map snd pairs))

      -- for each (Locus, [Next]) generate new state as CLOSURE([Next])
      -- and add all (ThisState => Locus => NewState) transitions to GOTO table.
      foldM (addItem index) (pool, GOTO goto') itemsByNextPoint

    -- for (Locus, [Next]) generate new state as CLOSURE([Next])
    -- and add (ThisState => Locus => NewState) transition to GOTO table.
    addItem :: State.Index -> (Set State.Index, LR1.GOTO.T) -> (Point.T, Set Item.T) -> m (Set State.Index, LR1.GOTO.T)
    addItem index (pool, GOTO goto) (point, items) = do
      -- NewState = CLOSURE([Next])
      (nextIndex, new) <- State.closure grammar first items

      -- if the new state was not registered yet, add it to the pool
      -- of next iteration
      let pool' = if new then Set.insert nextIndex pool else pool

      -- Add (ThisState => Locus => NewState) transition to GOTO.
      let goto' = Map.adjust (Map.insert point nextIndex) index goto
      return (pool', GOTO goto')

expected :: LR1.GOTO.T -> State.Index -> Map Point.T State.Index
expected (GOTO goto) index = goto Map.! index

dump :: State.HasReg m => Text -> LR1.GOTO.T -> m String
dump header (GOTO goto) = do
  let
    asList = goto
      & Map.toList
      & (fmap.fmap) Map.toList
  stateList <- for asList \(srcIndex, dests) -> do
    srcState <- uses State.indices (Map.! srcIndex)
    destStates <- for dests \(point, destIndex) -> do
      destState <- uses State.indices (Map.! destIndex)
      return (point, destState)
    return (srcState, destStates)

  let
    showBlock (src, dests)  = unlines (show src : fmap showDest dests)
    showDest  (point, dest) = "  " <> show point <> "\t" <> show dest

  return $ stateList
    & fmap showBlock
    & (Text.unpack header :)
    & unlines

(!?) :: [(Int, Int)] -> State.T -> State.T
table !? state = state { State.index = fromJust $ lookup (State.index state) table }