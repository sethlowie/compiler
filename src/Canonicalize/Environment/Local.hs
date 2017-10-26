{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}
module Canonicalize.Environment.Local
  ( addDeclarations
  )
  where


import Control.Applicative (liftA2)
import Control.Monad (foldM)
import qualified Data.Graph as Graph
import qualified Data.Map.Strict as Map
import qualified Data.Map.Merge.Strict as Map

import qualified AST.Expression.Valid as Valid
import qualified AST.Type as Type
import qualified Canonicalize.Bag as Bag
import qualified Canonicalize.Environment.Dups as Dups
import qualified Canonicalize.Environment.Internals as Env
import qualified Canonicalize.OneOrMore as OneOrMore
import qualified Canonicalize.Type as Type
import qualified Elm.Name as N
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Canonicalize as Error
import qualified Reporting.Region as R
import qualified Reporting.Result as Result



-- ADD DECLARATIONS


addDeclarations :: Valid.Module -> Env.Env -> Env.Result Env.Env
addDeclarations module_ env =
  addVars module_
  =<< addTypes module_
  =<< addBinops module_ (addPatterns module_ env)


merge
  :: (N.Name -> a -> homes)
  -> (N.Name -> a -> homes -> homes)
  -> Map.Map N.Name a
  -> Map.Map N.Name homes
  -> Map.Map N.Name homes
merge addLeft addBoth locals foreigns =
  let addRight _ homes = homes in
  Map.merge
    (Map.mapMissing addLeft)
    (Map.mapMissing addRight)
    (Map.zipWithMatched addBoth)
    locals
    foreigns



-- ADD PATTERNS
--
-- This does not return a Result because Dups.detect is already called in
-- collectUpperVars. This will detect all local pattern clashes. We skip it
-- here to avoid a second version of the same error.


addPatterns :: Valid.Module -> Env.Env -> Env.Env
addPatterns (Valid.Module _ _ _ _ _ _ unions _ _ _) (Env.Env home vars types patterns binops) =
  let
    unionToInfos (Valid.Union _ _ ctors) =
      map ctorToPair ctors

    ctorToPair (A.A _ name, args) =
      ( name, length args )

    localPatterns =
      Map.fromList $ concatMap unionToInfos unions

    addLeft _ arity =
      Env.Homes (Bag.one (home, arity)) Map.empty

    addBoth _ arity (Env.Homes _ qualified) =
      Env.Homes (Bag.one (home, arity)) qualified

    newPatterns =
      merge addLeft addBoth localPatterns patterns
  in
  Env.Env home vars types newPatterns binops



-- ADD BINOPS


addBinops :: Valid.Module -> Env.Env -> Env.Result Env.Env
addBinops (Valid.Module _ _ _ _ _ _ _ _ ops _) (Env.Env home vars types patterns binops) =
  let
    toInfo (Valid.Binop (A.A region op) assoc prec name) =
      Dups.info op region () (OneOrMore.one (Env.Binop home name assoc prec))

    toError op () () =
      Error.DuplicateBinop op
  in
  do  opDict <- Dups.detect toError $ map toInfo ops
      let newBinops = Map.unionWith OneOrMore.more opDict binops
      return $ Env.Env home vars types patterns newBinops



-- ADD VARS


addVars :: Valid.Module -> Env.Env -> Env.Result Env.Env
addVars module_ (Env.Env home vars types patterns binops) =
  do  upperDict <- collectUpperVars module_
      lowerDict <- collectLowerVars module_
      let varDict = Map.union upperDict lowerDict
      let newVars = addVarsHelp varDict vars
      return $ Env.Env home newVars types patterns binops


addVarsHelp :: Map.Map N.Name () -> Map.Map N.Name Env.VarHomes -> Map.Map N.Name Env.VarHomes
addVarsHelp localVars vars =
  let
    varHomes =
      Env.VarHomes Env.TopLevel Map.empty

    addLeft _ _ =
      varHomes

    addBoth _ _ (Env.VarHomes _ qualified) =
      Env.VarHomes Env.TopLevel qualified
  in
  merge addLeft addBoth localVars vars


collectLowerVars :: Valid.Module -> Env.Result (Map.Map N.Name ())
collectLowerVars (Valid.Module _ _ _ _ _ decls _ _ _ effects) =
  let
    declToInfo (Valid.Decl (A.A region name) _ _ _) =
      Dups.info name region () ()

    portToInfo (Valid.Port (A.A region name) _) =
      Dups.info name region () ()

    effectInfo =
      case effects of
        Valid.NoEffects ->
          []

        Valid.Ports ports ->
          map portToInfo ports

        Valid.Cmd (A.A region _) ->
          [ Dups.info "command" region () () ]

        Valid.Sub (A.A region _) ->
          [ Dups.info "subscription" region () () ]

        Valid.Fx (A.A regionCmd _) (A.A regionSub _) ->
          [ Dups.info "command" regionCmd () ()
          , Dups.info "subscription" regionSub () ()
          ]

    toError name () () =
      Error.DuplicateDecl name
  in
  Dups.detect toError $
    effectInfo ++ map declToInfo decls


collectUpperVars :: Valid.Module -> Env.Result (Map.Map N.Name ())
collectUpperVars (Valid.Module _ _ _ _ _ _ unions aliases _ _) =
  let
    unionToInfos (Valid.Union (A.A _ name) _ ctors) =
      map (ctorToInfo name) ctors

    ctorToInfo tipe (A.A region name, _args) =
      Dups.info name region (Error.UnionCtor tipe) ()

    aliasToInfos (Valid.Alias (A.A region name) _ (A.A _ tipe)) =
      case tipe of
        Type.RRecord _ Nothing ->
          [ Dups.info name region Error.RecordCtor () ]

        _ ->
          []
  in
  Dups.detect Error.DuplicateCtor $
    concatMap aliasToInfos aliases ++ concatMap unionToInfos unions



-- ADD TYPES


addTypes :: Valid.Module -> Env.Env -> Env.Result Env.Env
addTypes (Valid.Module _ _ _ _ _ _ unions aliases _ _) env =
  let
    aliasToInfo alias@(Valid.Alias (A.A region name) _ tipe) =
      do  args <- checkAliasFreeVars alias
          return $ Dups.info name region () (Left (Alias region name args tipe))

    unionToInfo union@(Valid.Union (A.A region name) _ _) =
      do  arity <- checkUnionFreeVars union
          return $ Dups.info name region () (Right arity)

    toError name () () =
      Error.DuplicateType name

    infos =
      liftA2 (++)
        (traverse aliasToInfo aliases)
        (traverse unionToInfo unions)
  in
  do  types <- Dups.detect toError =<< infos
      let (aliasDict, unionDict) = Map.mapEither id types
      addTypeAliases aliasDict (addUnionTypes unionDict env)


addUnionTypes :: Map.Map N.Name Int -> Env.Env -> Env.Env
addUnionTypes unions (Env.Env home vars types patterns binops) =
  let
    unionHome =
      Env.Union home

    addLeft _ arity =
      Env.Homes (Bag.one (unionHome, arity)) Map.empty

    addBoth _ arity (Env.Homes _ qualified) =
      Env.Homes (Bag.one (unionHome, arity)) qualified

    newTypes =
      merge addLeft addBoth unions types
  in
  Env.Env home vars newTypes patterns binops



-- ADD TYPE ALIASES


data Alias =
  Alias
    { _region :: R.Region
    , _name :: N.Name
    , _args :: [N.Name]
    , _type :: Type.Raw
    }


addTypeAliases :: Map.Map N.Name Alias -> Env.Env -> Env.Result Env.Env
addTypeAliases aliases env =
  do  let nodes = map toNode (Map.elems aliases)
      let sccs = Graph.stronglyConnComp nodes
      foldM addTypeAlias env sccs


addTypeAlias :: Env.Env -> Graph.SCC Alias -> Env.Result Env.Env
addTypeAlias env@(Env.Env home vars types patterns binops) scc =
  case scc of
    Graph.AcyclicSCC (Alias _ name args tipe) ->
      do  ctype <- Type.canonicalize env tipe
          let info = (Env.Alias home args ctype, length args)
          let newTypes = Map.alter (addAliasInfo info) name types
          return $ Env.Env home vars newTypes patterns binops

    Graph.CyclicSCC [] ->
      Result.ok env

    Graph.CyclicSCC (Alias region name1 args tipe : others) ->
      let toName (Alias _ name _ _) = name in
      Result.throw region (Error.AliasRecursion name1 args tipe (map toName others))


addAliasInfo :: a -> Maybe (Env.Homes a) -> Maybe (Env.Homes a)
addAliasInfo info maybeHomes =
  Just $
    case maybeHomes of
      Nothing ->
        Env.Homes (Bag.one info) Map.empty

      Just (Env.Homes _ qualified) ->
        Env.Homes (Bag.one info) qualified



-- DETECT TYPE ALIAS CYCLES


toNode :: Alias -> ( Alias, N.Name, [N.Name] )
toNode alias@(Alias _ name _ tipe) =
  ( alias, name, Bag.toList (getEdges tipe) )


getEdges :: Type.Raw -> Bag.Bag N.Name
getEdges (A.A _ tipe) =
  case tipe of
    Type.RLambda arg result ->
      Bag.append (getEdges arg) (getEdges result)

    Type.RVar _ ->
      Bag.empty

    Type.RType _ Nothing name args ->
      foldr Bag.append (Bag.one name) (map getEdges args)

    Type.RType _ (Just _) _ args ->
      foldr Bag.append Bag.empty (map getEdges args)

    Type.RRecord fields ext ->
      foldr Bag.append (maybe Bag.empty getEdges ext) (map (getEdges . snd) fields)

    Type.RUnit ->
      Bag.empty

    Type.RTuple a b cs ->
      foldr Bag.append (getEdges a) (getEdges b : map getEdges cs)



-- CHECK FREE VARIABLES


checkUnionFreeVars :: Valid.Union -> Env.Result Int
checkUnionFreeVars (Valid.Union (A.A unionRegion name) args ctors) =
  let
    toInfo (A.A region arg) =
      Dups.info arg region () region

    toError badArg () () =
      Error.DuplicateUnionArg name badArg (map A.drop args)

    addCtorFreeVars (_, tipes) freeVars =
      foldr addFreeVars freeVars tipes
  in
  do  boundVars <- Dups.detect toError (map toInfo args)
      let freeVars = foldr addCtorFreeVars Map.empty ctors
      case Map.toList (Map.difference freeVars boundVars) of
        [] ->
          Result.ok (length args)

        unbound ->
          let toLoc (arg, region) = A.A region arg in
          Result.throw unionRegion $
            Error.TypeVarsUnboundInUnion name (map A.drop args) (map toLoc unbound)



checkAliasFreeVars :: Valid.Alias -> Env.Result [N.Name]
checkAliasFreeVars (Valid.Alias (A.A aliasRegion name) args tipe) =
  let
    toInfo (A.A region arg) =
      Dups.info arg region () region

    toError badArg () () =
      Error.DuplicateAliasArg name badArg (map A.drop args)
  in
  do  boundVars <- Dups.detect toError (map toInfo args)
      let freeVars = addFreeVars tipe Map.empty
      let overlap = Map.size (Map.intersection boundVars freeVars)
      if Map.size boundVars == overlap && Map.size freeVars == overlap
        then Result.ok (map A.drop args)
        else
          let toLoc (arg, region) = A.A region arg in
          Result.throw aliasRegion $
            Error.TypeVarsMessedUpInAlias name
              (map A.drop args)
              (map toLoc (Map.toList (Map.difference boundVars freeVars)))
              (map toLoc (Map.toList (Map.difference freeVars boundVars)))


addFreeVars :: Type.Raw -> Map.Map N.Name R.Region -> Map.Map N.Name R.Region
addFreeVars (A.A region tipe) freeVars =
  case tipe of
    Type.RLambda arg result ->
      addFreeVars arg (addFreeVars result freeVars)

    Type.RVar name ->
      Map.insert name region freeVars

    Type.RType _ _ _ args ->
      foldr addFreeVars freeVars args

    Type.RRecord fields ext ->
      foldr addFreeVars (maybe id addFreeVars ext freeVars) (map snd fields)

    Type.RUnit ->
      freeVars

    Type.RTuple a b cs ->
      foldr addFreeVars freeVars (a:b:cs)
