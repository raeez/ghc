%
% (c) The University of Glasgow 2006
%

\begin{code}
-- | Module for (a) type kinds and (b) type coercions, 
-- as used in System FC. See 'CoreSyn.Expr' for
-- more on System FC and how coercions fit into it.
--
module Coercion (
        -- * Main data type
        Coercion(..), Var, CoVar,

        -- ** Deconstructing Kinds 
        kindFunResult, kindAppResult, synTyConResKind,
        splitKindFunTys, splitKindFunTysN, splitKindFunTy_maybe,

        -- ** Predicates on Kinds
        isLiftedTypeKind, isUnliftedTypeKind, isOpenTypeKind,
        isUbxTupleKind, isArgTypeKind, isKind, isTySuperKind, 
        isSuperKind, isCoercionKind, 
	mkArrowKind, mkArrowKinds,

        isSubArgTypeKind, isSubOpenTypeKind, isSubKind, defaultKind, eqKind,
        isSubKindCon,

        mkCoType, coVarKind, coVarKind_maybe,
        coercionType, coercionKind, coercionKinds, isReflCo,

	-- ** Constructing coercions
        mkReflCo, mkCoVarCo,
        mkAxInstCo, mkPiCo, mkPiCos,
        mkSymCo, mkTransCo, mkNthCo,
	mkInstCo, mkAppCo, mkTyConAppCo, mkFunCo,
        mkForAllCo, mkUnsafeCo,
        mkNewTypeCo, mkFamInstCo, 
        mkPredCo,

        -- ** Decomposition
        splitCoPredTy_maybe,
        splitNewTypeRepCo_maybe, instNewTyCon_maybe, decomposeCo,
        getCoVar_maybe,

        splitTyConAppCo_maybe,
        splitAppCo_maybe,
        splitForAllCo_maybe,

	-- ** Coercion variables
	mkCoVar, isCoVar, isCoVarType, coVarName, setCoVarName, setCoVarUnique,

        -- ** Free variables
        tyCoVarsOfCo, tyCoVarsOfCos, coVarsOfCo, coercionSize,
	
        -- ** Substitution
        CvSubstEnv, emptyCvSubstEnv, 
 	CvSubst(..), emptyCvSubst, Coercion.lookupTyVar, lookupCoVar,
	isEmptyCvSubst, zapCvSubstEnv, getCvInScope,
        substCo, substCos, substCoVar, substCoVars,
        substCoWithTy, substCoWithTys, 
	cvTvSubst, tvCvSubst, zipOpenCvSubst,
        substTy, extendTvSubst,
	substTyVarBndr, substCoVarBndr,

	-- ** Lifting
	liftCoMatch, liftCoSubstTyVar, liftCoSubstWith, 
        
        -- ** Comparison
        coreEqCoercion, coreEqCoercion2,

        -- ** Forcing evaluation of coercions
        seqCo,
        
        -- * Pretty-printing
        pprCo, pprParendCo, pprCoAxiom,

        -- * Other
        applyCo, coVarPred
        
       ) where 

#include "HsVersions.h"

import Unify	( MatchEnv(..), matchList )
import TypeRep
import qualified Type
import Type hiding( substTy, substTyVarBndr, extendTvSubst )
import Kind
import Class	( classTyCon )
import TyCon
import Var
import VarEnv
import VarSet
import Maybes	( orElse )
import Name	( Name, NamedThing(..), nameUnique )
import OccName 	( parenSymOcc )
import Util
import BasicTypes
import Outputable
import Unique
import Pair
import TysPrim		( eqPredPrimTyCon )
import PrelNames	( funTyConKey, eqPredPrimTyConKey )
import Control.Applicative
import Data.Traversable (traverse, sequenceA)
import Control.Arrow (second)
import FastString

import qualified Data.Data as Data hiding ( TyCon )
\end{code}

%************************************************************************
%*									*
            Coercions
%*									*
%************************************************************************

\begin{code}
-- | A 'Coercion' is concrete evidence of the equality/convertibility
-- of two types.

data Coercion 
  -- These ones mirror the shape of types
  = Refl Type  -- See Note [Refl invariant]
          -- Invariant: applications of (Refl T) to a bunch of identity coercions
          --            always show up as Refl.
          -- For example  (Refl T) (Refl a) (Refl b) shows up as (Refl (T a b)).

          -- Applications of (Refl T) to some coercions, at least one of
          -- which is NOT the identity, show up as TyConAppCo.
          -- (They may not be fully saturated however.)
          -- ConAppCo coercions (like all coercions other than Refl)
          -- are NEVER the identity.

  -- These ones simply lift the correspondingly-named 
  -- Type constructors into Coercions
  | TyConAppCo TyCon [Coercion]    -- lift TyConApp 
    	       -- The TyCon is never a synonym; 
	       -- we expand synonyms eagerly

  | AppCo Coercion Coercion        -- lift AppTy

  -- See Note [Forall coercions]
  | ForAllCo TyVar Coercion       -- forall a. g

  -- These are special
  | CoVarCo CoVar
  | AxiomInstCo CoAxiom [Coercion]  -- The coercion arguments always *precisely*
                                    -- saturate arity of CoAxiom.
                                    -- See [Coercion axioms applied to coercions]
  | UnsafeCo Type Type
  | SymCo Coercion
  | TransCo Coercion Coercion

  -- These are destructors
  | NthCo Int Coercion          -- Zero-indexed
  | InstCo Coercion Type
  deriving (Data.Data, Data.Typeable)
\end{code}

Note [Refl invariant]
~~~~~~~~~~~~~~~~~~~~~
Coercions have the following invariant 
     Refl is always lifted as far as possible.  

You might think that a consequencs is:
     Every identity coercions has Refl at the root

But that's not quite true because of coercion variables.  Consider
     g         where g :: Int~Int
     Left h    where h :: Maybe Int ~ Maybe Int
etc.  So the consequence is only true of coercions that
have no coercion variables.

Note [Coercion axioms applied to coercions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The reason coercion axioms can be applied to coercions and not just
types is to allow for better optimization.  There are some cases where
we need to be able to "push transitivity inside" an axiom in order to
expose further opportunities for optimization.  

For example, suppose we have

  C a : t[a] ~ F a
  g   : b ~ c

and we want to optimize

  sym (C b) ; t[g] ; C c

which has the kind

  F b ~ F c

(stopping through t[b] and t[c] along the way).

We'd like to optimize this to just F g -- but how?  The key is
that we need to allow axioms to be instantiated by *coercions*,
not just by types.  Then we can (in certain cases) push
transitivity inside the axiom instantiations, and then react
opposite-polarity instantiations of the same axiom.  In this
case, e.g., we match t[g] against the LHS of (C c)'s kind, to
obtain the substitution  a |-> g  (note this operation is sort
of the dual of lifting!) and hence end up with

  C g : t[b] ~ F c

which indeed has the same kind as  t[g] ; C c.

Now we have

  sym (C b) ; C g

which can be optimized to F g.


Note [Forall coercions]
~~~~~~~~~~~~~~~~~~~~~~~
Constructing coercions between forall-types can be a bit tricky.
Currently, the situation is as follows:

  ForAllCo TyVar Coercion

represents a coercion between polymorphic types, with the rule

           v : k       g : t1 ~ t2
  ----------------------------------------------
  ForAllCo v g : (all v:k . t1) ~ (all v:k . t2)

Note that it's only necessary to coerce between polymorphic types
where the type variables have identical kinds, because equality on
kinds is trivial.

Note [Predicate coercions]
~~~~~~~~~~~~~~~~~~~~~~~~~~
Suppose we have
   g :: a~b
How can we coerce between types
   ([c]~a) => [a] -> c
and
   ([c]~b) => [b] -> c
where the equality predicate *itself* differs?

Answer: we simply treat (~) as an ordinary type constructor, so these
types really look like

   ((~) [c] a) -> [a] -> c
   ((~) [c] b) -> [b] -> c

So the coercion between the two is obviously

   ((~) [c] g) -> [g] -> c

Another way to see this to say that we simply collapse predicates to
their representation type (see Type.coreView and Type.predTypeRep).

This collapse is done by mkPredCo; there is no PredCo constructor
in Coercion.  This is important because we need Nth to work on 
predicates too:
    Nth 1 ((~) [c] g) = g
See Simplify.simplCoercionF, which generates such selections.

%************************************************************************
%*									*
\subsection{Coercion variables}
%*									*
%************************************************************************

\begin{code}
coVarName :: CoVar -> Name
coVarName = varName

setCoVarUnique :: CoVar -> Unique -> CoVar
setCoVarUnique = setVarUnique

setCoVarName :: CoVar -> Name -> CoVar
setCoVarName   = setVarName

isCoVar :: Var -> Bool
isCoVar v = isCoVarType (varType v)

isCoVarType :: Type -> Bool
-- Don't rely on a PredTy; look at the representation type
isCoVarType ty 
  | Just tc <- tyConAppTyCon_maybe ty = tc `hasKey` eqPredPrimTyConKey
  | otherwise                         = False
\end{code}


\begin{code}
tyCoVarsOfCo :: Coercion -> VarSet
-- Extracts type and coercion variables from a coercion
tyCoVarsOfCo (Refl ty)           = tyVarsOfType ty
tyCoVarsOfCo (TyConAppCo _ cos)  = tyCoVarsOfCos cos
tyCoVarsOfCo (AppCo co1 co2)     = tyCoVarsOfCo co1 `unionVarSet` tyCoVarsOfCo co2
tyCoVarsOfCo (ForAllCo tv co)    = tyCoVarsOfCo co `delVarSet` tv
tyCoVarsOfCo (CoVarCo v)         = unitVarSet v
tyCoVarsOfCo (AxiomInstCo _ cos) = tyCoVarsOfCos cos
tyCoVarsOfCo (UnsafeCo ty1 ty2)  = tyVarsOfType ty1 `unionVarSet` tyVarsOfType ty2
tyCoVarsOfCo (SymCo co)          = tyCoVarsOfCo co
tyCoVarsOfCo (TransCo co1 co2)   = tyCoVarsOfCo co1 `unionVarSet` tyCoVarsOfCo co2
tyCoVarsOfCo (NthCo _ co)        = tyCoVarsOfCo co
tyCoVarsOfCo (InstCo co ty)      = tyCoVarsOfCo co `unionVarSet` tyVarsOfType ty

tyCoVarsOfCos :: [Coercion] -> VarSet
tyCoVarsOfCos cos = foldr (unionVarSet . tyCoVarsOfCo) emptyVarSet cos

coVarsOfCo :: Coercion -> VarSet
-- Extract *coerction* variables only.  Tiresome to repeat the code, but easy.
coVarsOfCo (Refl _)            = emptyVarSet
coVarsOfCo (TyConAppCo _ cos)  = coVarsOfCos cos
coVarsOfCo (AppCo co1 co2)     = coVarsOfCo co1 `unionVarSet` coVarsOfCo co2
coVarsOfCo (ForAllCo _ co)     = coVarsOfCo co
coVarsOfCo (CoVarCo v)         = unitVarSet v
coVarsOfCo (AxiomInstCo _ cos) = coVarsOfCos cos
coVarsOfCo (UnsafeCo _ _)      = emptyVarSet
coVarsOfCo (SymCo co)          = coVarsOfCo co
coVarsOfCo (TransCo co1 co2)   = coVarsOfCo co1 `unionVarSet` coVarsOfCo co2
coVarsOfCo (NthCo _ co)        = coVarsOfCo co
coVarsOfCo (InstCo co _)       = coVarsOfCo co

coVarsOfCos :: [Coercion] -> VarSet
coVarsOfCos cos = foldr (unionVarSet . coVarsOfCo) emptyVarSet cos

coercionSize :: Coercion -> Int
coercionSize (Refl ty)           = typeSize ty
coercionSize (TyConAppCo _ cos)  = 1 + sum (map coercionSize cos)
coercionSize (AppCo co1 co2)     = coercionSize co1 + coercionSize co2
coercionSize (ForAllCo _ co)     = 1 + coercionSize co
coercionSize (CoVarCo _)         = 1
coercionSize (AxiomInstCo _ cos) = 1 + sum (map coercionSize cos)
coercionSize (UnsafeCo ty1 ty2)  = typeSize ty1 + typeSize ty2
coercionSize (SymCo co)          = 1 + coercionSize co
coercionSize (TransCo co1 co2)   = 1 + coercionSize co1 + coercionSize co2
coercionSize (NthCo _ co)        = 1 + coercionSize co
coercionSize (InstCo co ty)      = 1 + coercionSize co + typeSize ty
\end{code}

%************************************************************************
%*									*
                   Pretty-printing coercions
%*                                                                      *
%************************************************************************

@pprCo@ is the standard @Coercion@ printer; the overloaded @ppr@
function is defined to use this.  @pprParendCo@ is the same, except it
puts parens around the type, except for the atomic cases.
@pprParendCo@ works just by setting the initial context precedence
very high.

\begin{code}
instance Outputable Coercion where
  ppr = pprCo

pprCo, pprParendCo :: Coercion -> SDoc
pprCo       co = ppr_co TopPrec   co
pprParendCo co = ppr_co TyConPrec co

ppr_co :: Prec -> Coercion -> SDoc
ppr_co _ (Refl ty) = angles (ppr ty)

ppr_co p co@(TyConAppCo tc cos)
  | tc `hasKey` funTyConKey = ppr_fun_co p co
  | otherwise               = pprTcApp   p ppr_co tc cos

ppr_co p (AppCo co1 co2)    = maybeParen p TyConPrec $
                              pprCo co1 <+> ppr_co TyConPrec co2

ppr_co p co@(ForAllCo {}) = ppr_forall_co p co

ppr_co _ (CoVarCo cv)     = parenSymOcc (getOccName cv) (ppr cv)

ppr_co p (AxiomInstCo con cos) = pprTypeNameApp p ppr_co (getName con) cos


ppr_co p (TransCo co1 co2) = maybeParen p FunPrec $
                             ppr_co FunPrec co1
                             <+> ptext (sLit ";")
                             <+> ppr_co FunPrec co2
ppr_co p (InstCo co ty) = maybeParen p TyConPrec $
                          pprParendCo co <> ptext (sLit "@") <> pprType ty

ppr_co p (UnsafeCo ty1 ty2) = pprPrefixApp p (ptext (sLit "UnsafeCo")) [pprParendType ty1, pprParendType ty2]
ppr_co p (SymCo co)         = pprPrefixApp p (ptext (sLit "Sym")) [pprParendCo co]
ppr_co p (NthCo n co)       = pprPrefixApp p (ptext (sLit "Nth:") <+> int n) [pprParendCo co]


angles :: SDoc -> SDoc
angles p = char '<' <> p <> char '>'

ppr_fun_co :: Prec -> Coercion -> SDoc
ppr_fun_co p co = pprArrowChain p (split co)
  where
    split (TyConAppCo f [arg,res])
      | f `hasKey` funTyConKey
      = ppr_co FunPrec arg : split res
    split co = [ppr_co TopPrec co]

ppr_forall_co :: Prec -> Coercion -> SDoc
ppr_forall_co p ty
  = maybeParen p FunPrec $
    sep [pprForAll tvs, ppr_co TopPrec rho]
  where
    (tvs,  rho) = split1 [] ty
    split1 tvs (ForAllCo tv ty) = split1 (tv:tvs) ty
    split1 tvs ty               = (reverse tvs, ty)
\end{code}

\begin{code}
pprCoAxiom :: CoAxiom -> SDoc
pprCoAxiom ax
  = sep [ ptext (sLit "axiom") <+> ppr ax <+> ppr (co_ax_tvs ax)
        , nest 2 (dcolon <+> pprEqPred (Pair (co_ax_lhs ax) (co_ax_rhs ax))) ]
\end{code}

%************************************************************************
%*									*
	Functions over Kinds		
%*									*
%************************************************************************

\begin{code}
-- | This breaks a 'Coercion' with type @T A B C ~ T D E F@ into
-- a list of 'Coercion's of kinds @A ~ D@, @B ~ E@ and @E ~ F@. Hence:
--
-- > decomposeCo 3 c = [nth 0 c, nth 1 c, nth 2 c]
decomposeCo :: Arity -> Coercion -> [Coercion]
decomposeCo arity co = [mkNthCo n co | n <- [0..(arity-1)] ]

-- | Attempts to obtain the type variable underlying a 'Coercion'
getCoVar_maybe :: Coercion -> Maybe CoVar
getCoVar_maybe (CoVarCo cv) = Just cv  
getCoVar_maybe _            = Nothing

-- | Attempts to tease a coercion apart into a type constructor and the application
-- of a number of coercion arguments to that constructor
splitTyConAppCo_maybe :: Coercion -> Maybe (TyCon, [Coercion])
splitTyConAppCo_maybe (Refl ty)           = (fmap . second . map) Refl (splitTyConApp_maybe ty)
splitTyConAppCo_maybe (TyConAppCo tc cos) = Just (tc, cos)
splitTyConAppCo_maybe _                   = Nothing

splitAppCo_maybe :: Coercion -> Maybe (Coercion, Coercion)
-- ^ Attempt to take a coercion application apart.
splitAppCo_maybe (AppCo co1 co2) = Just (co1, co2)
splitAppCo_maybe (TyConAppCo tc cos)
  | isDecomposableTyCon tc || cos `lengthExceeds` tyConArity tc 
  , Just (cos', co') <- snocView cos
  = Just (mkTyConAppCo tc cos', co')    -- Never create unsaturated type family apps!
       -- Use mkTyConAppCo to preserve the invariant
       --  that identity coercions are always represented by Refl
splitAppCo_maybe (Refl ty) 
  | Just (ty1, ty2) <- splitAppTy_maybe ty 
  = Just (Refl ty1, Refl ty2)
splitAppCo_maybe _ = Nothing

splitForAllCo_maybe :: Coercion -> Maybe (TyVar, Coercion)
splitForAllCo_maybe (ForAllCo tv co) = Just (tv, co)
splitForAllCo_maybe _                = Nothing

-------------------------------------------------------
-- and some coercion kind stuff

coVarPred :: CoVar -> PredType
coVarPred cv = case coVarKind_maybe cv of
  Just (ty1, ty2) -> mkEqPred (ty1, ty2)
  Nothing         -> pprPanic "coVarPred" (ppr cv $$ ppr (varType cv))

coVarKind :: CoVar -> (Type,Type) 
-- c :: t1 ~ t2
coVarKind cv = case coVarKind_maybe cv of
                 Just ts -> ts
                 Nothing -> pprPanic "coVarKind" (ppr cv $$ ppr (tyVarKind cv))

coVarKind_maybe :: CoVar -> Maybe (Type,Type) 
coVarKind_maybe cv = case splitTyConApp_maybe (varType cv) of
  Just (tc, [ty1, ty2]) | tc `hasKey` eqPredPrimTyConKey -> Just (ty1, ty2)
  _ -> Nothing

-- | Makes a coercion type from two types: the types whose equality 
-- is proven by the relevant 'Coercion'
mkCoType :: Type -> Type -> Type
mkCoType ty1 ty2 = PredTy (EqPred ty1 ty2)

splitCoPredTy_maybe :: Type -> Maybe (Type, Type, Type)
splitCoPredTy_maybe ty
  | Just (cv,r) <- splitForAllTy_maybe ty
  , isCoVar cv
  , Just (s,t) <- coVarKind_maybe cv
  = Just (s,t,r)
  | otherwise
  = Nothing

isReflCo :: Coercion -> Bool
isReflCo (Refl {}) = True
isReflCo _         = False

isReflCo_maybe :: Coercion -> Maybe Type
isReflCo_maybe (Refl ty) = Just ty
isReflCo_maybe _         = Nothing
\end{code}

%************************************************************************
%*									*
            Building coercions
%*									*
%************************************************************************

\begin{code}
mkCoVarCo :: CoVar -> Coercion
mkCoVarCo cv
  | ty1 `eqType` ty2 = Refl ty1
  | otherwise        = CoVarCo cv
  where
    (ty1, ty2) = ASSERT( isCoVar cv ) coVarKind cv

mkReflCo :: Type -> Coercion
mkReflCo = Refl

mkAxInstCo :: CoAxiom -> [Type] -> Coercion
mkAxInstCo ax tys
  | arity == n_tys = AxiomInstCo ax rtys
  | otherwise      = ASSERT( arity < n_tys )
                     foldl AppCo (AxiomInstCo ax (take arity rtys))
                                 (drop arity rtys)
  where
    n_tys = length tys
    arity = coAxiomArity ax
    rtys  = map Refl tys

-- | Apply a 'Coercion' to another 'Coercion'.
mkAppCo :: Coercion -> Coercion -> Coercion
mkAppCo (Refl ty1) (Refl ty2)       = Refl (mkAppTy ty1 ty2)
mkAppCo (Refl (TyConApp tc tys)) co = TyConAppCo tc (map Refl tys ++ [co])
mkAppCo (TyConAppCo tc cos) co      = TyConAppCo tc (cos ++ [co])
mkAppCo co1 co2                     = AppCo co1 co2
-- Note, mkAppCo is careful to maintain invariants regarding
-- where Refl constructors appear; see the comments in the definition
-- of Coercion and the Note [Refl invariant] in types/TypeRep.lhs.

-- | Applies multiple 'Coercion's to another 'Coercion', from left to right.
-- See also 'mkAppCo'
mkAppCos :: Coercion -> [Coercion] -> Coercion
mkAppCos co1 tys = foldl mkAppCo co1 tys

-- | Apply a type constructor to a list of coercions.
mkTyConAppCo :: TyCon -> [Coercion] -> Coercion
mkTyConAppCo tc cos
	       -- Expand type synonyms
  | Just (tv_co_prs, rhs_ty, leftover_cos) <- tcExpandTyCon_maybe tc cos
  = mkAppCos (liftCoSubst tv_co_prs rhs_ty) leftover_cos

  | Just tys <- traverse isReflCo_maybe cos 
  = Refl (mkTyConApp tc tys)	-- See Note [Refl invariant]

  | otherwise = TyConAppCo tc cos

-- | Make a function 'Coercion' between two other 'Coercion's
mkFunCo :: Coercion -> Coercion -> Coercion
mkFunCo co1 co2 = mkTyConAppCo funTyCon [co1, co2]

-- | Make a 'Coercion' which binds a variable within an inner 'Coercion'
mkForAllCo :: Var -> Coercion -> Coercion
-- note that a TyVar should be used here, not a CoVar (nor a TcTyVar)
mkForAllCo tv (Refl ty) = ASSERT( isTyVar tv ) Refl (mkForAllTy tv ty)
mkForAllCo tv  co       = ASSERT ( isTyVar tv ) ForAllCo tv co

mkPredCo :: Pred Coercion -> Coercion
-- See Note [Predicate coercions]
mkPredCo (EqPred co1 co2) = mkTyConAppCo eqPredPrimTyCon [co1,co2]
mkPredCo (ClassP cls cos) = mkTyConAppCo (classTyCon cls) cos
mkPredCo (IParam _ co)    = co

-------------------------------

-- | Create a symmetric version of the given 'Coercion' that asserts
--   equality between the same types but in the other "direction", so
--   a kind of @t1 ~ t2@ becomes the kind @t2 ~ t1@.
mkSymCo :: Coercion -> Coercion

-- Do a few simple optimizations, but don't bother pushing occurrences
-- of symmetry to the leaves; the optimizer will take care of that.
mkSymCo co@(Refl {})              = co
mkSymCo    (UnsafeCo ty1 ty2)    = UnsafeCo ty2 ty1
mkSymCo    (SymCo co)            = co
mkSymCo co                       = SymCo co

-- | Create a new 'Coercion' by composing the two given 'Coercion's transitively.
mkTransCo :: Coercion -> Coercion -> Coercion
mkTransCo (Refl _) co = co
mkTransCo co (Refl _) = co
mkTransCo co1 co2     = TransCo co1 co2

mkNthCo :: Int -> Coercion -> Coercion
mkNthCo n (Refl ty) = Refl (getNth n ty)
mkNthCo n co        = NthCo n co

-- | Instantiates a 'Coercion' with a 'Type' argument. 
mkInstCo :: Coercion -> Type -> Coercion
mkInstCo co ty = InstCo co ty

-- | Manufacture a coercion from thin air. Needless to say, this is
--   not usually safe, but it is used when we know we are dealing with
--   bottom, which is one case in which it is safe.  This is also used
--   to implement the @unsafeCoerce#@ primitive.  Optimise by pushing
--   down through type constructors.
mkUnsafeCo :: Type -> Type -> Coercion
mkUnsafeCo ty1 ty2 | ty1 `eqType` ty2 = Refl ty1
mkUnsafeCo (TyConApp tc1 tys1) (TyConApp tc2 tys2)
  | tc1 == tc2
  = mkTyConAppCo tc1 (zipWith mkUnsafeCo tys1 tys2)

mkUnsafeCo (FunTy a1 r1) (FunTy a2 r2)
  = mkFunCo (mkUnsafeCo a1 a2) (mkUnsafeCo r1 r2)

mkUnsafeCo ty1 ty2 = UnsafeCo ty1 ty2

-- See note [Newtype coercions] in TyCon

-- | Create a coercion constructor (axiom) suitable for the given
--   newtype 'TyCon'. The 'Name' should be that of a new coercion
--   'CoAxiom', the 'TyVar's the arguments expected by the @newtype@ and
--   the type the appropriate right hand side of the @newtype@, with
--   the free variables a subset of those 'TyVar's.
mkNewTypeCo :: Name -> TyCon -> [TyVar] -> Type -> CoAxiom
mkNewTypeCo name tycon tvs rhs_ty
  = CoAxiom { co_ax_unique = nameUnique name
            , co_ax_name   = name
            , co_ax_tvs    = tvs
            , co_ax_lhs    = mkTyConApp tycon (mkTyVarTys tvs)
            , co_ax_rhs    = rhs_ty }

-- | Create a coercion identifying a @data@, @newtype@ or @type@ representation type
-- and its family instance.  It has the form @Co tvs :: F ts ~ R tvs@, where @Co@ is 
-- the coercion constructor built here, @F@ the family tycon and @R@ the (derived)
-- representation tycon.
mkFamInstCo :: Name	-- ^ Unique name for the coercion tycon
		  -> [TyVar]	-- ^ Type parameters of the coercion (@tvs@)
		  -> TyCon	-- ^ Family tycon (@F@)
		  -> [Type]	-- ^ Type instance (@ts@)
		  -> TyCon	-- ^ Representation tycon (@R@)
		  -> CoAxiom	-- ^ Coercion constructor (@Co@)
mkFamInstCo name tvs family inst_tys rep_tycon
  = CoAxiom { co_ax_unique = nameUnique name
            , co_ax_name   = name
            , co_ax_tvs    = tvs
            , co_ax_lhs    = mkTyConApp family inst_tys 
            , co_ax_rhs    = mkTyConApp rep_tycon (mkTyVarTys tvs) }

mkPiCos :: [Var] -> Coercion -> Coercion
mkPiCos vs co = foldr mkPiCo co vs

mkPiCo  :: Var -> Coercion -> Coercion
mkPiCo v co | isTyVar v = mkForAllCo v co
            | otherwise = mkFunCo (mkReflCo (varType v)) co
\end{code}

%************************************************************************
%*									*
            Newtypes
%*									*
%************************************************************************

\begin{code}
instNewTyCon_maybe :: TyCon -> [Type] -> Maybe (Type, Coercion)
-- ^ If @co :: T ts ~ rep_ty@ then:
--
-- > instNewTyCon_maybe T ts = Just (rep_ty, co)
instNewTyCon_maybe tc tys
  | Just (tvs, ty, co_tc) <- unwrapNewTyCon_maybe tc
  = ASSERT( tys `lengthIs` tyConArity tc )
    Just (substTyWith tvs tys ty, mkAxInstCo co_tc tys)
  | otherwise
  = Nothing

-- this is here to avoid module loops
splitNewTypeRepCo_maybe :: Type -> Maybe (Type, Coercion)  
-- ^ Sometimes we want to look through a @newtype@ and get its associated coercion.
-- This function only strips *one layer* of @newtype@ off, so the caller will usually call
-- itself recursively. Furthermore, this function should only be applied to types of kind @*@,
-- hence the newtype is always saturated. If @co : ty ~ ty'@ then:
--
-- > splitNewTypeRepCo_maybe ty = Just (ty', co)
--
-- The function returns @Nothing@ for non-@newtypes@ or fully-transparent @newtype@s.
splitNewTypeRepCo_maybe ty 
  | Just ty' <- coreView ty = splitNewTypeRepCo_maybe ty'
splitNewTypeRepCo_maybe (TyConApp tc tys)
  | Just (ty', co) <- instNewTyCon_maybe tc tys
  = case co of
	Refl _ -> panic "splitNewTypeRepCo_maybe"
			-- This case handled by coreView
	_      -> Just (ty', co)
splitNewTypeRepCo_maybe _
  = Nothing

-- | Determines syntactic equality of coercions
coreEqCoercion :: Coercion -> Coercion -> Bool
coreEqCoercion co1 co2 = coreEqCoercion2 rn_env co1 co2
  where rn_env = mkRnEnv2 (mkInScopeSet (tyCoVarsOfCo co1 `unionVarSet` tyCoVarsOfCo co2))

coreEqCoercion2 :: RnEnv2 -> Coercion -> Coercion -> Bool
coreEqCoercion2 env (Refl ty1) (Refl ty2) = eqTypeX env ty1 ty2
coreEqCoercion2 env (TyConAppCo tc1 cos1) (TyConAppCo tc2 cos2)
  = tc1 == tc2 && all2 (coreEqCoercion2 env) cos1 cos2

coreEqCoercion2 env (AppCo co11 co12) (AppCo co21 co22)
  = coreEqCoercion2 env co11 co21 && coreEqCoercion2 env co12 co22

coreEqCoercion2 env (ForAllCo v1 co1) (ForAllCo v2 co2)
  = coreEqCoercion2 (rnBndr2 env v1 v2) co1 co2

coreEqCoercion2 env (CoVarCo cv1) (CoVarCo cv2)
  = rnOccL env cv1 == rnOccR env cv2

coreEqCoercion2 env (AxiomInstCo con1 cos1) (AxiomInstCo con2 cos2)
  = con1 == con2
    && all2 (coreEqCoercion2 env) cos1 cos2

coreEqCoercion2 env (UnsafeCo ty11 ty12) (UnsafeCo ty21 ty22)
  = eqTypeX env ty11 ty21 && eqTypeX env ty12 ty22

coreEqCoercion2 env (SymCo co1) (SymCo co2)
  = coreEqCoercion2 env co1 co2

coreEqCoercion2 env (TransCo co11 co12) (TransCo co21 co22)
  = coreEqCoercion2 env co11 co21 && coreEqCoercion2 env co12 co22

coreEqCoercion2 env (NthCo d1 co1) (NthCo d2 co2)
  = d1 == d2 && coreEqCoercion2 env co1 co2

coreEqCoercion2 env (InstCo co1 ty1) (InstCo co2 ty2)
  = coreEqCoercion2 env co1 co2 && eqTypeX env ty1 ty2

coreEqCoercion2 _ _ _ = False
\end{code}

%************************************************************************
%*									*
                   Substitution of coercions
%*                                                                      *
%************************************************************************

\begin{code}
-- | A substitution of 'Coercion's for 'CoVar's (OR 'TyVar's, when
--   doing a \"lifting\" substitution)
type CvSubstEnv = VarEnv Coercion

emptyCvSubstEnv :: CvSubstEnv
emptyCvSubstEnv = emptyVarEnv

data CvSubst 		
  = CvSubst InScopeSet 	-- The in-scope type variables
	    TvSubstEnv	-- Substitution of types
            CvSubstEnv  -- Substitution of coercions

instance Outputable CvSubst where
  ppr (CvSubst ins tenv cenv)
    = brackets $ sep[ ptext (sLit "CvSubst"),
		      nest 2 (ptext (sLit "In scope:") <+> ppr ins), 
		      nest 2 (ptext (sLit "Type env:") <+> ppr tenv),
		      nest 2 (ptext (sLit "Coercion env:") <+> ppr cenv) ]

emptyCvSubst :: CvSubst
emptyCvSubst = CvSubst emptyInScopeSet emptyVarEnv emptyVarEnv

isEmptyCvSubst :: CvSubst -> Bool
isEmptyCvSubst (CvSubst _ tenv cenv) = isEmptyVarEnv tenv && isEmptyVarEnv cenv

getCvInScope :: CvSubst -> InScopeSet
getCvInScope (CvSubst in_scope _ _) = in_scope

zapCvSubstEnv :: CvSubst -> CvSubst
zapCvSubstEnv (CvSubst in_scope _ _) = CvSubst in_scope emptyVarEnv emptyVarEnv

cvTvSubst :: CvSubst -> TvSubst
cvTvSubst (CvSubst in_scope tvs _) = TvSubst in_scope tvs

tvCvSubst :: TvSubst -> CvSubst
tvCvSubst (TvSubst in_scope tenv) = CvSubst in_scope tenv emptyCvSubstEnv

extendTvSubst :: CvSubst -> TyVar -> Type -> CvSubst
extendTvSubst (CvSubst in_scope tenv cenv) tv ty
  = CvSubst in_scope (extendVarEnv tenv tv ty) cenv

substCoVarBndr :: CvSubst -> CoVar -> (CvSubst, CoVar)
substCoVarBndr subst@(CvSubst in_scope tenv cenv) old_var
  = ASSERT( isCoVar old_var )
    (CvSubst (in_scope `extendInScopeSet` new_var) tenv new_cenv, new_var)
  where
    -- When we substitute (co :: t1 ~ t2) we may get the identity (co :: t ~ t)
    -- In that case, mkCoVarCo will return a ReflCoercion, and
    -- we want to substitute that (not new_var) for old_var
    new_co    = mkCoVarCo new_var
    no_change = new_var == old_var && not (isReflCo new_co)

    new_cenv | no_change = delVarEnv cenv old_var
             | otherwise = extendVarEnv cenv old_var new_co

    new_var = uniqAway in_scope subst_old_var
    subst_old_var = mkCoVar (varName old_var) (substTy subst (varType old_var))
		  -- It's important to do the substitution for coercions,
		  -- because only they can have free type variables

substTyVarBndr :: CvSubst -> TyVar -> (CvSubst, TyVar)
substTyVarBndr (CvSubst in_scope tenv cenv) old_var
  = case Type.substTyVarBndr (TvSubst in_scope tenv) old_var of
      (TvSubst in_scope' tenv', new_var) -> (CvSubst in_scope' tenv' cenv, new_var)

zipOpenCvSubst :: [Var] -> [Coercion] -> CvSubst
zipOpenCvSubst vs cos
  | debugIsOn && (length vs /= length cos)
  = pprTrace "zipOpenCvSubst" (ppr vs $$ ppr cos) emptyCvSubst
  | otherwise 
  = CvSubst (mkInScopeSet (tyCoVarsOfCos cos)) emptyTvSubstEnv (zipVarEnv vs cos)

substCoWithTy :: InScopeSet -> TyVar -> Type -> Coercion -> Coercion
substCoWithTy in_scope tv ty = substCoWithTys in_scope [tv] [ty]

substCoWithTys :: InScopeSet -> [TyVar] -> [Type] -> Coercion -> Coercion
substCoWithTys in_scope tvs tys co
  | debugIsOn && (length tvs /= length tys)
  = pprTrace "substCoWithTys" (ppr tvs $$ ppr tys) co
  | otherwise 
  = ASSERT( length tvs == length tys )
    substCo (CvSubst in_scope (zipVarEnv tvs tys) emptyVarEnv) co

-- | Substitute within a 'Coercion'
substCo :: CvSubst -> Coercion -> Coercion
substCo subst co | isEmptyCvSubst subst = co
                 | otherwise            = subst_co subst co

-- | Substitute within several 'Coercion's
substCos :: CvSubst -> [Coercion] -> [Coercion]
substCos subst cos | isEmptyCvSubst subst = cos
                   | otherwise            = map (substCo subst) cos

substTy :: CvSubst -> Type -> Type
substTy subst = Type.substTy (cvTvSubst subst)

subst_co :: CvSubst -> Coercion -> Coercion
subst_co subst co
  = go co
  where
    go_ty :: Type -> Type
    go_ty = Coercion.substTy subst

    go :: Coercion -> Coercion
    go (Refl ty)             = Refl $! go_ty ty
    go (TyConAppCo tc cos)   = let args = map go cos
                               in  args `seqList` TyConAppCo tc args
    go (AppCo co1 co2)       = mkAppCo (go co1) $! go co2
    go (ForAllCo tv co)      = case substTyVarBndr subst tv of
                                 (subst', tv') ->
                                   ForAllCo tv' $! subst_co subst' co
    go (CoVarCo cv)          = substCoVar subst cv
    go (AxiomInstCo con cos) = AxiomInstCo con $! map go cos
    go (UnsafeCo ty1 ty2)    = (UnsafeCo $! go_ty ty1) $! go_ty ty2
    go (SymCo co)            = mkSymCo (go co)
    go (TransCo co1 co2)     = mkTransCo (go co1) (go co2)
    go (NthCo d co)          = mkNthCo d (go co)
    go (InstCo co ty)        = mkInstCo (go co) $! go_ty ty

substCoVar :: CvSubst -> CoVar -> Coercion
substCoVar (CvSubst in_scope _ cenv) cv
  | Just co  <- lookupVarEnv cenv cv      = co
  | Just cv1 <- lookupInScope in_scope cv = ASSERT( isCoVar cv1 ) CoVarCo cv1
  | otherwise = WARN( True, ptext (sLit "substCoVar not in scope") <+> ppr cv $$ ppr in_scope)
                ASSERT( isCoVar cv ) CoVarCo cv

substCoVars :: CvSubst -> [CoVar] -> [Coercion]
substCoVars subst cvs = map (substCoVar subst) cvs

lookupTyVar :: CvSubst -> TyVar  -> Maybe Type
lookupTyVar (CvSubst _ tenv _) tv = lookupVarEnv tenv tv

lookupCoVar :: CvSubst -> Var  -> Maybe Coercion
lookupCoVar (CvSubst _ _ cenv) v = lookupVarEnv cenv v
\end{code}

%************************************************************************
%*									*
                   "Lifting" substitution
	   [(TyVar,Coercion)] -> Type -> Coercion
%*                                                                      *
%************************************************************************

\begin{code}
data LiftCoSubst = LCS InScopeSet LiftCoEnv

type LiftCoEnv = VarEnv Coercion
     -- Maps *type variables* to *coercions*
     -- That's the whole point of this function!

liftCoSubstWith :: [TyVar] -> [Coercion] -> Type -> Coercion
liftCoSubstWith tvs cos ty
  = liftCoSubst (zipEqual "liftCoSubstWith" tvs cos) ty

liftCoSubst :: [(TyVar,Coercion)] -> Type -> Coercion
liftCoSubst prs ty
 | null prs  = Refl ty
 | otherwise = ty_co_subst (LCS (mkInScopeSet (tyCoVarsOfCos (map snd prs)))
                                (mkVarEnv prs)) ty

-- | The \"lifting\" operation which substitutes coercions for type
--   variables in a type to produce a coercion.
--
--   For the inverse operation, see 'liftCoMatch' 
ty_co_subst :: LiftCoSubst -> Type -> Coercion
ty_co_subst subst ty
  = go ty
  where
    go (TyVarTy tv)      = liftCoSubstTyVar subst tv `orElse` Refl (TyVarTy tv)
       			     -- A type variable from a non-cloned forall
			     -- won't be in the substitution
    go (AppTy ty1 ty2)   = mkAppCo (go ty1) (go ty2)
    go (TyConApp tc tys) = mkTyConAppCo tc (map go tys)
    go (FunTy ty1 ty2)   = mkFunCo (go ty1) (go ty2)
    go (ForAllTy v ty)   = mkForAllCo v' $! (ty_co_subst subst' ty)
                         where
                           (subst', v') = liftCoSubstTyVarBndr subst v
    go (PredTy p)        = mkPredCo (go <$> p)

liftCoSubstTyVar :: LiftCoSubst -> TyVar -> Maybe Coercion
liftCoSubstTyVar (LCS _ cenv) tv = lookupVarEnv cenv tv 

liftCoSubstTyVarBndr :: LiftCoSubst -> TyVar -> (LiftCoSubst, TyVar)
liftCoSubstTyVarBndr (LCS in_scope cenv) old_var
  = (LCS (in_scope `extendInScopeSet` new_var) new_cenv, new_var)		
  where
    new_cenv | no_change = delVarEnv cenv old_var
	     | otherwise = extendVarEnv cenv old_var (Refl (TyVarTy new_var))

    no_change = new_var == old_var
    new_var = uniqAway in_scope old_var
\end{code}

\begin{code}
-- | 'liftCoMatch' is sort of inverse to 'liftCoSubst'.  In particular, if
--   @liftCoMatch vars ty co == Just s@, then @tyCoSubst s ty == co@.
--   That is, it matches a type against a coercion of the same
--   "shape", and returns a lifting substitution which could have been
--   used to produce the given coercion from the given type.
liftCoMatch :: TyVarSet -> Type -> Coercion -> Maybe LiftCoSubst
liftCoMatch tmpls ty co 
  = case ty_co_match menv emptyVarEnv ty co of
      Just cenv -> Just (LCS in_scope cenv)
      Nothing   -> Nothing
  where
    menv     = ME { me_tmpls = tmpls, me_env = mkRnEnv2 in_scope }
    in_scope = mkInScopeSet (tmpls `unionVarSet` tyCoVarsOfCo co)
    -- Like tcMatchTy, assume all the interesting variables 
    -- in ty are in tmpls

-- | 'ty_co_match' does all the actual work for 'liftCoMatch'.
ty_co_match :: MatchEnv -> LiftCoEnv -> Type -> Coercion -> Maybe LiftCoEnv
ty_co_match menv subst ty co 
  | Just ty' <- coreView ty = ty_co_match menv subst ty' co

  -- Match a type variable against a non-refl coercion
ty_co_match menv cenv (TyVarTy tv1) co
  | Just co1' <- lookupVarEnv cenv tv1'      -- tv1' is already bound to co1
  = if coreEqCoercion2 (nukeRnEnvL rn_env) co1' co
    then Just cenv
    else Nothing       -- no match since tv1 matches two different coercions

  | tv1' `elemVarSet` me_tmpls menv           -- tv1' is a template var
  = if any (inRnEnvR rn_env) (varSetElems (tyCoVarsOfCo co))
    then Nothing      -- occurs check failed
    else return (extendVarEnv cenv tv1' co)
        -- BAY: I don't think we need to do any kind matching here yet
        -- (compare 'match'), but we probably will when moving to SHE.

  | otherwise    -- tv1 is not a template ty var, so the only thing it
                 -- can match is a reflexivity coercion for itself.
		 -- But that case is dealt with already
  = Nothing

  where
    rn_env = me_env menv
    tv1' = rnOccL rn_env tv1

ty_co_match menv subst (AppTy ty1 ty2) co
  | Just (co1, co2) <- splitAppCo_maybe co	-- c.f. Unify.match on AppTy
  = do { subst' <- ty_co_match menv subst ty1 co1 
       ; ty_co_match menv subst' ty2 co2 }

ty_co_match menv subst (TyConApp tc1 tys) (TyConAppCo tc2 cos)
  | tc1 == tc2 = ty_co_matches menv subst tys cos

ty_co_match menv subst (FunTy ty1 ty2) (TyConAppCo tc cos)
  | tc == funTyCon = ty_co_matches menv subst [ty1,ty2] cos

ty_co_match menv subst (ForAllTy tv1 ty) (ForAllCo tv2 co) 
  = ty_co_match menv' subst ty co
  where
    menv' = menv { me_env = rnBndr2 (me_env menv) tv1 tv2 }

ty_co_match menv subst ty co
  | Just co' <- pushRefl co = ty_co_match menv subst ty co'
  | otherwise               = Nothing

ty_co_matches :: MatchEnv -> LiftCoEnv -> [Type] -> [Coercion] -> Maybe LiftCoEnv
ty_co_matches menv = matchList (ty_co_match menv)

pushRefl :: Coercion -> Maybe Coercion
pushRefl (Refl (AppTy ty1 ty2))   = Just (AppCo (Refl ty1) (Refl ty2))
pushRefl (Refl (FunTy ty1 ty2))   = Just (TyConAppCo funTyCon [Refl ty1, Refl ty2])
pushRefl (Refl (TyConApp tc tys)) = Just (TyConAppCo tc (map Refl tys))
pushRefl (Refl (ForAllTy tv ty))  = Just (ForAllCo tv (Refl ty))
pushRefl _                        = Nothing
\end{code}

%************************************************************************
%*									*
            Sequencing on coercions
%*									*
%************************************************************************

\begin{code}
seqCo :: Coercion -> ()
seqCo (Refl ty)             = seqType ty
seqCo (TyConAppCo tc cos)   = tc `seq` seqCos cos
seqCo (AppCo co1 co2)       = seqCo co1 `seq` seqCo co2
seqCo (ForAllCo tv co)      = tv `seq` seqCo co
seqCo (CoVarCo cv)          = cv `seq` ()
seqCo (AxiomInstCo con cos) = con `seq` seqCos cos
seqCo (UnsafeCo ty1 ty2)    = seqType ty1 `seq` seqType ty2
seqCo (SymCo co)            = seqCo co
seqCo (TransCo co1 co2)     = seqCo co1 `seq` seqCo co2
seqCo (NthCo _ co)          = seqCo co
seqCo (InstCo co ty)        = seqCo co `seq` seqType ty

seqCos :: [Coercion] -> ()
seqCos []       = ()
seqCos (co:cos) = seqCo co `seq` seqCos cos
\end{code}


%************************************************************************
%*									*
	     The kind of a type, and of a coercion
%*									*
%************************************************************************

\begin{code}
coercionType :: Coercion -> Type
coercionType co = case coercionKind co of
                    Pair ty1 ty2 -> mkCoType ty1 ty2

------------------
-- | If it is the case that
--
-- > c :: (t1 ~ t2)
--
-- i.e. the kind of @c@ relates @t1@ and @t2@, then @coercionKind c = Pair t1 t2@.
coercionKind :: Coercion -> Pair Type
coercionKind (Refl ty)            = Pair ty ty
coercionKind (TyConAppCo tc cos)  = mkTyConApp tc <$> (sequenceA $ map coercionKind cos)
coercionKind (AppCo co1 co2)      = mkAppTy <$> coercionKind co1 <*> coercionKind co2
coercionKind (ForAllCo tv co)     = mkForAllTy tv <$> coercionKind co
coercionKind (CoVarCo cv)         = ASSERT( isCoVar cv ) toPair $ coVarKind cv
coercionKind (AxiomInstCo ax cos) = let Pair tys1 tys2 = coercionKinds cos
                                    in  Pair (substTyWith (co_ax_tvs ax) tys1 (co_ax_lhs ax)) 
                                             (substTyWith (co_ax_tvs ax) tys2 (co_ax_rhs ax))
coercionKind (UnsafeCo ty1 ty2)   = Pair ty1 ty2
coercionKind (SymCo co)           = swap $ coercionKind co
coercionKind (TransCo co1 co2)    = Pair (pFst $ coercionKind co1) (pSnd $ coercionKind co2)
coercionKind (NthCo d co)         = getNth d <$> coercionKind co
coercionKind co@(InstCo aco ty)    | Just ks <- splitForAllTy_maybe `traverse` coercionKind aco
                                  = (\(tv, body) -> substTyWith [tv] [ty] body) <$> ks
				  | otherwise = pprPanic "coercionKind" (ppr co)

-- | Apply 'coercionKind' to multiple 'Coercion's
coercionKinds :: [Coercion] -> Pair [Type]
coercionKinds tys = sequenceA $ map coercionKind tys

getNth :: Int -> Type -> Type
getNth n ty | Just tys <- tyConAppArgs_maybe ty
            = ASSERT2( n < length tys, ppr n <+> ppr tys ) tys !! n
getNth n ty = pprPanic "getNth" (ppr n <+> ppr ty)
\end{code}

\begin{code}
applyCo :: Type -> Coercion -> Type
-- Gives the type of (e co) where e :: (a~b) => ty
applyCo ty co | Just ty' <- coreView ty = applyCo ty' co
applyCo (FunTy _ ty) _ = ty
applyCo _            _ = panic "applyCo"
\end{code}