{-# OPTIONS_GHC -Wno-orphans #-}
{- |
  A parser state.

  Is a set of `Item.T`.

  You can get one as a first state, or a closure of next items from a subset of other state -
  a subset with the same next point.

  This state @N@

  @
      { E <- [E] + F { ) }
        X <- [E]     { $ end }
        T <- [begin] G [end] { $ }
      }
  @

  can produce, on @E@, the following state @M@:

  @
      CLOSURE(
        { E <- E [+] F { ) }
          X <- E []    { $ end }
        }
      )
  @

  This means if parser is in the state @N@ and has entity @E@ on top of the
  stack, it can go into the state @M@, which assumes that @E@ is parsed and is
  on top of the stack.
-}
module LR1.State where

import Control.Arrow ((&&&))
import Control.Monad.State qualified as MTL
import Data.Function (on, (&))
import Data.List (groupBy, sortOn)
import Data.Set (Set)
import Data.Set qualified as Set
import GHC.Generics (Generic)

import LR1.FIRST   qualified as FIRST
import LR1.Grammar qualified as Grammar
import LR1.Item    qualified as Item
import LR1.Map     qualified as Map
import LR1.Point   qualified as Point
import LR1.Term    qualified as Term
import LR1.Utils (fixpoint, one, Get ((?)))

{- |
  We don't want to haul sets of items around (and spend 50% time in set comparison!)
  (believe me, I did ._.).

  So, we need better representation of the state.

  I've decided to store 1-1 state <-> index map in the state monad and carry
  mere `Int`-s around.
-}
type Index = Int

{- |
  Don't ask.
-}
deriving stock instance Generic Int

{- |
  The parser state.
-}
data T = State
  { index  :: Index       -- ^ It's index in the registry.
  , items  :: Set Item.T  -- ^ Items it contains.
  , kernel :: Set Item.T  -- ^ Items it is built from.
  }

instance Eq LR1.State.T where
  (==) = (==) `on` items

instance Ord LR1.State.T where
  compare = compare `on` items

instance Show LR1.State.T where
  show State { kernel = set, index } =
    "(" <> show index <> ")\n"
      <> foldMap (\item -> "  " <> show item <> "\n") set

{- |
  State registry.
-}
data Reg = Reg
  { states  :: Map.T LR1.State.T Index  -- ^ `T` -> `Index`
  , indices :: Map.T Index LR1.State.T  -- ^ `Index` -> `T`
  , counter :: Index                    -- ^ Last index allocated.
  }

{- |
  Empty state registry.
-}
emptyReg :: Reg
emptyReg = Reg
  { states  = Map.empty
  , indices = Map.empty
  , counter = 0
  }

-- makeLenses ''Reg

{- |
  It is shorter.
-}
type HasReg m = MTL.MonadState Reg m

{- |
  Build a CLOSURE() of item set, given the grammar and FIRST table.

  Also returns if new state was /completely/ new and wasn't discovered yet.
-}
closure :: HasReg m => Grammar.T -> FIRST.T -> Set Item.T -> m (LR1.State.Index, Bool)
closure grammar first items = do
  let
    state = fixpoint items do
      foldMap do
        \item1 -> case Item.locus item1 of
          Nothing -> mempty
          Just (Point.Term _) -> mempty
          Just (Point.NonTerm entity) -> do
            let
              localahead = case Item.next item1 >>= Item.locus of
                Nothing -> Item.lookahead item1
                Just (Point.Term term) -> one term
                Just (Point.NonTerm nextEntity) -> first ? nextEntity

            grammar ? entity & Set.map (Item.start localahead)

  register (State (error "state index is not set") (normalize state) items)
  where
    normalize :: Set Item.T -> Set Item.T
    normalize items' =
      items'
        & Set.toList
        & groupBy ((==) `on` (Item.entity &&& Item.label &&& Item.pos))
        & fmap do \list@(item : _) -> item { Item.lookahead = Set.unions $ fmap Item.lookahead list }
        & Set.fromList

    register :: HasReg m => LR1.State.T -> m (Index, Bool)
    register state = do
      MTL.gets (Map.lookup state . states) >>= \case
        Nothing -> do
          index <- MTL.gets counter
          let state1 = state { index }
          MTL.modify \Reg {states, indices, counter} -> Reg
            { states  = Map.insert state1 index states
            , indices = Map.insert index state1 indices
            , counter = 1 + counter
            }
          return (index, True)

        Just n -> do
          return (n, False)


{- |
  Get the first state of the grammar.
-}
firstState :: HasReg m => Grammar.T -> FIRST.T -> m Index
firstState grammar first =
  fst <$> closure grammar first
    ( one
    $ Item.start (one Term.EndOfStream)
    $ Grammar.firstRule grammar
    )

instance Show Reg where
  show Reg {states} = do
    Map.keys states
      & sortOn index
      & fmap show
      & unlines
