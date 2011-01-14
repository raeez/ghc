
module Vectorise.Utils.PADict (
	paDictArgType,
	paDictOfType,
	paMethod	
)
where
import Vectorise.Monad
import Vectorise.Builtins
import Vectorise.Utils.Base

import CoreSyn
import CoreUtils
import Coercion
import Type
import TypeRep
import TyCon
import Var
import Outputable
import FastString
import Control.Monad


-- | Construct the PA argument type for the tyvar. For the tyvar (v :: *) it's
-- just PA v. For (v :: (* -> *) -> *) it's
--
-- > forall (a :: * -> *). (forall (b :: *). PA b -> PA (a b)) -> PA (v a)
--
paDictArgType :: TyVar -> VM (Maybe Type)
paDictArgType tv = go (TyVarTy tv) (tyVarKind tv)
  where
    go ty k | Just k' <- kindView k = go ty k'
    go ty (FunTy k1 k2)
      = do
          tv   <- newTyVar (fsLit "a") k1
          mty1 <- go (TyVarTy tv) k1
          case mty1 of
            Just ty1 -> do
                          mty2 <- go (AppTy ty (TyVarTy tv)) k2
                          return $ fmap (ForAllTy tv . FunTy ty1) mty2
            Nothing  -> go ty k2

    go ty k
      | isLiftedTypeKind k
      = liftM Just (mkBuiltinTyConApp paTyCon [ty])

    go _ _ = return Nothing


-- | Get the PA dictionary for some type
--
paDictOfType :: Type -> VM CoreExpr
paDictOfType ty 
  = paDictOfTyApp ty_fn ty_args
  where
    (ty_fn, ty_args) = splitAppTys ty

    paDictOfTyApp :: Type -> [Type] -> VM CoreExpr
    paDictOfTyApp ty_fn ty_args
        | Just ty_fn' <- coreView ty_fn 
        = paDictOfTyApp ty_fn' ty_args

    -- for type variables, look up the dfun and apply to the PA dictionaries
    -- of the type arguments
    paDictOfTyApp (TyVarTy tv) ty_args
     = do dfun <- maybeCantVectoriseM "No PA dictionary for type variable"
                                      (ppr tv <+> text "in" <+> ppr ty)
                $ lookupTyVarPA tv
          dicts <- mapM paDictOfType ty_args
          return $ dfun `mkTyApps` ty_args `mkApps` dicts

    -- for tycons, we also need to apply the dfun to the PR dictionary of
    -- the representation type if the tycon is polymorphic
    paDictOfTyApp (TyConApp tc []) ty_args
     = do
         dfun <- maybeCantVectoriseM "No PA dictionary for type constructor"
                                      (ppr tc <+> text "in" <+> ppr ty)
                $ lookupTyConPA tc
         super <- super_dict tc ty_args
         dicts <- mapM paDictOfType ty_args
         return $ Var dfun `mkTyApps` ty_args `mkApps` super `mkApps` dicts

    paDictOfTyApp _ _ = failure

    super_dict _ [] = return []
    super_dict tycon ty_args
      = do
          pr <- prDictOfPReprInst (TyConApp tycon ty_args)
          return [pr]

    failure = cantVectorise "Can't construct PA dictionary for type" (ppr ty)

paMethod :: (Builtins -> Var) -> String -> Type -> VM CoreExpr
paMethod _ name ty
  | Just tycon <- splitPrimTyCon ty
  = liftM Var
  . maybeCantVectoriseM "No PA method" (text name <+> text "for" <+> ppr tycon)
  $ lookupPrimMethod tycon name

paMethod method _ ty
  = do
      fn   <- builtin method
      dict <- paDictOfType ty
      return $ mkApps (Var fn) [Type ty, dict]

-- | Given a type @ty@, return the PR dictionary for @PRepr ty@.
prDictOfPReprInst :: Type -> VM CoreExpr
prDictOfPReprInst ty
  = do
      (prepr_tc, prepr_args) <- preprSynTyCon ty
      case coreView (mkTyConApp prepr_tc prepr_args) of
        Just rhs -> do
                      dict <- prDictOfReprType rhs
                      pr_co <- mkBuiltinCo prTyCon
                      let Just arg_co = tyConFamilyCoercion_maybe prepr_tc
                      let co = mkAppCoercion pr_co
                             $ mkSymCoercion
                             $ mkTyConApp arg_co prepr_args
                      return $ mkCoerce co dict
        Nothing  -> cantVectorise "Invalid PRepr type instance"
                                  $ ppr ty

-- | Get the PR dictionary for a type. The argument must be a representation
-- type.
prDictOfReprType :: Type -> VM CoreExpr
prDictOfReprType ty
  | Just (tycon, tyargs) <- splitTyConApp_maybe ty
    = do
        prepr <- builtin preprTyCon
        if tycon == prepr
          then do
                 [ty'] <- return tyargs
                 prDictOfPReprInst ty'
          else do 
                 -- a representation tycon must have a PR instance
                 dfun <- maybeCantVectoriseM
                           "No PR dictionary for type constructor"
                           (ppr tycon <+> text "in" <+> ppr ty)
                       $ lookupTyConPR tycon
                 prDFunApply dfun tyargs

  | otherwise
    = do
        -- it is a tyvar or an application of a tyvar
        -- determine the PR dictionary from its PA dictionary
        --
        -- NOTE: This assumes that PRepr t ~ t is for all representation types
        -- t
        --
        -- FIXME: This doesn't work for kinds other than * at the moment. We'd
        -- have to simply abstract the term over the missing type arguments.
        pa    <- paDictOfType ty
        prsel <- builtin paPRSel
        return $ Var prsel `mkApps` [Type ty, pa]

-- | Apply a tycon's PR dfun to dictionary arguments (PR or PA) corresponding
-- to the argument types.
prDFunApply :: Var -> [Type] -> VM CoreExpr
prDFunApply dfun tys
  | Just [] <- ctxs    -- PR (a :-> b) doesn't have a context
  = return $ Var dfun `mkTyApps` tys

  | Just tycons <- ctxs
  , length tycons == length tys
  = do
      pa <- builtin paTyCon
      pr <- builtin prTyCon 
      args <- zipWithM (dictionary pa pr) tys tycons
      return $ Var dfun `mkTyApps` tys `mkApps` args

  | otherwise = invalid
  where
    -- the dfun's contexts - if its type is (PA a, PR b) => PR (C a b) then
    -- ctxs is Just [PA, PR]
    ctxs = fmap (map fst)
         $ sequence
         $ map splitTyConApp_maybe
         $ fst
         $ splitFunTys
         $ snd
         $ splitForAllTys
         $ varType dfun

    dictionary pa pr ty tycon
      | tycon == pa = paDictOfType ty
      | tycon == pr = prDictOfReprType ty
      | otherwise   = invalid

    invalid = cantVectorise "Invalid PR dfun type" (ppr (varType dfun) <+> ppr tys)
 