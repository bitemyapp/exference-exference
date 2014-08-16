module TypeClasses where



import Type
import Unify
import qualified Data.Set as S
import qualified Data.Map.Strict as M
import Data.Foldable ( fold, foldMap )
import Data.List ( intercalate )
import Debug.Hood.Observe
import Debug.Trace
import Data.Maybe ( fromMaybe )
import Control.Applicative ( (<$>) )
import Control.Monad ( mplus, guard )
import Data.Functor.Identity ( Identity(runIdentity) )

import Debug.Hood.Observe


data HsTypeClass = HsTypeClass
  { tclass_name :: String
  , tclass_params :: [TVarId]
  , tclass_constraints :: [Constraint]
  }
  deriving (Eq, Show, Ord)

data HsInstance = HsInstance
  { instance_constraints :: [Constraint]
  , instance_tclass :: HsTypeClass
  , instance_params :: [HsType]
  }
  deriving (Eq, Show, Ord)

data Constraint = Constraint
  { constraint_tclass :: HsTypeClass
  , constraint_params :: [HsType]
  }
  deriving (Eq, Ord)

data StaticContext = StaticContext
  { context_tclasses :: [HsTypeClass]
  , context_instances :: [HsInstance]
  }
  deriving Show

data DynContext = DynContext
  { dynContext_context :: StaticContext
  , dynContext_constraints :: S.Set Constraint
  , dynContext_varConstraints :: M.Map TVarId (S.Set Constraint)
  }

instance Show Constraint where
  show (Constraint c ps) = intercalate " " $ tclass_name c : map show ps

instance Show DynContext where
  show (DynContext _ cs _) = "(DynContext _ " ++ show cs ++ " _)"
instance Observable Constraint where
  observer x parent = observeOpaque (show x) x parent

instance Observable DynContext where
  observer x parent = observeOpaque (show x) x parent

emptyContext :: StaticContext
emptyContext = StaticContext {
  context_tclasses = [],
  context_instances = []
}

constraintMapTypes :: (HsType -> HsType) -> Constraint -> Constraint
constraintMapTypes f (Constraint a ts) = Constraint a (map f ts)

defaultContext :: StaticContext
defaultContext = StaticContext {
  context_tclasses = [c_show, c_functor, c_applicative, c_monad],
  context_instances = [list_show, list_functor, list_applicative, list_monad]
  --context_redirects = M.Map TVarId TVarId
}

c_show           = HsTypeClass "Show" [badReadVar "a"] []
c_functor        = HsTypeClass "Functor" [badReadVar "f"] []
c_applicative    = HsTypeClass "Applicative" [badReadVar "f"]
                                             [Constraint c_functor [read "f"]]
c_monad          = HsTypeClass "Monad" [badReadVar "m"]
                                       [Constraint c_applicative [read "m"]]
c_monadState     = HsTypeClass
                     "MonadState"
                     [badReadVar "s", badReadVar "m"]
                     [Constraint c_monad [read "m"]]
list_show        = HsInstance [Constraint c_show [read "a"]] c_show [read "List a"]
list_functor     = HsInstance [] c_functor     [read "List a"]
list_applicative = HsInstance [] c_applicative [read "List a"]
list_monad       = HsInstance [] c_monad       [read "List a"]


mkDynContext :: StaticContext -> [Constraint] -> DynContext
mkDynContext staticContext constrs = DynContext {
  dynContext_context = defaultContext,
  dynContext_constraints = csSet,
  dynContext_varConstraints = helper constrs
}
  where
    csSet = S.fromList constrs
    helper :: [Constraint] -> M.Map TVarId (S.Set Constraint)
    helper cs =
      let ids :: S.Set TVarId
          ids = fold $ freeVars <$> (constraint_params =<< cs)
      in M.fromSet (flip filterConstraintsByVarId
                    $ inflateConstraints staticContext csSet) ids

testDynContext = mkDynContext defaultContext
    [ Constraint c_show [read "v"]
    , Constraint c_show [read "w"]
    , Constraint c_functor [read "x"]
    , Constraint c_monad   [read "y"]
    , Constraint c_monadState [read "s", read "z"]
    , Constraint c_show [read "MyFoo"]
    , Constraint c_show [read "B"]
    ]

constraintApplySubsts :: Substs -> Constraint -> Constraint
constraintApplySubsts ss (Constraint c ps) = Constraint c $ map (applySubsts ss) ps

inflateConstraints :: StaticContext -> S.Set Constraint -> S.Set Constraint
inflateConstraints context = inflate (S.fromList . f)
  where
    f :: Constraint -> [Constraint]
    f (Constraint (HsTypeClass _ ids constrs) ps) =
      (map (constraintApplySubsts $ M.fromList $ zip ids ps) constrs)

filterConstraintsByVarId :: TVarId -> S.Set Constraint -> S.Set Constraint
filterConstraintsByVarId i = S.filter (\c -> or $ map (containsVar i) $ constraint_params c)

constraintMatches :: DynContext -> TVarId -> HsType -> Bool
constraintMatches dcontext constrVar providedType =
  let contextConstraints  = dynContext_constraints dcontext
      relevantConstraints = fromMaybe S.empty
                          $ M.lookup constrVar $ dynContext_varConstraints dcontext
      wantedConstraints   = S.map
            (constraintApplySubsts $ M.singleton constrVar providedType)
            relevantConstraints
  in S.isSubsetOf wantedConstraints
    $ inflateConstraints
        (dynContext_context dcontext)
        contextConstraints
{-
 problem:
  given a set of constraints C over type variables a,b,c,..
    (for example: C={Monad m, Num a, Num b, Ord b})
  for each tuple of variables (v1,v2),
  can v1 be replaced by v2 without breaking the constraints?
  i.e. are the constraints for v1 a subset of the
    constraints for v2?


f :: Show a => a -> String
g :: Show b => [b]
is (f g) valid?

f :: Functor f => f x -> f ()
g :: Monad m => m Bool
is (f g) valid? YES (m ambiguous)

f :: Applicative f => f x -> f ()
g :: MonadState String m => m ()
is (f g) valid? YES (but m is ambiguous)

f :: Monad (WriterT w m) => WriterT w m () -> WriterT w m ()
g :: MonadState Bool m => WriterT w m ()
is (f g) valid?   NO

f :: Functor f, Show x => f x -> f String
g :: Monad m, Show y => m [y]
is (f g) valid?
-}

-- uses f to find new elements. adds these new elements, and recursively
-- tried to find even more elements. will not terminate if there are cycles
-- in the application of f
inflate :: (Ord a, Show a) => (a -> S.Set a) -> S.Set a -> S.Set a
inflate f = fold . S.fromList . iterateWhileNonempty (foldMap f)
  where
    iterateWhileNonempty f x = if S.null x
      then []
      else x : iterateWhileNonempty f (f x)

isProvable :: DynContext -> [Constraint] -> Bool
isProvable _ [] = True
isProvable dcontext (c1:constraints) =
  let
    provableFromContext :: Constraint -> Bool
    provableFromContext c = and
      [ S.member c $ inflateConstraints
                                (dynContext_context dcontext)
                                (dynContext_constraints dcontext)
      , isProvable dcontext constraints
      ]
    provableFromInstance :: Constraint -> Bool
    provableFromInstance (Constraint c ps) = or $ do
      HsInstance instConstrs inst instParams <- context_instances 
                                              $ dynContext_context dcontext
      guard $ inst==c
      let tempTuplePs     = foldl TypeApp (TypeCons "NTUPLE") ps
          tempTupleInstPs = foldl TypeApp (TypeCons "NTUPLE") instParams
      case unifyRight tempTuplePs tempTupleInstPs of -- or other way round?
        Nothing     -> []
        Just substs ->
          return $ isProvable dcontext
                 $ [constraintApplySubsts substs instC | instC <- instConstrs] ++ constraints
  in
    provableFromContext c1 || provableFromInstance c1

dynContextAddConstraints :: [Constraint] -> DynContext -> DynContext
dynContextAddConstraints cs (DynContext a b _) =
  mkDynContext a (cs ++ S.toList b)
