module IRTS.CodegenSe(codegenSe) where

import IRTS.CodegenCommon
import IRTS.Lang
import IRTS.Simplified
import Idris.Core.TT

import Data.Maybe
import Data.Char
import Data.List
import Data.Text (unpack)

codegenSe :: CodeGenerator
codegenSe ci = do let out = concatMap doCodegen (simpleDecls ci)
                      exports = concat (concatMap cgExport (exportDecls ci))
                  writeFile (outputFile ci) ("\n" ++ helpers ++ "\n" ++
                                                        out ++ "\n#exports:\n" ++
                                                        exports ++ "\n#/exports" ++
                                                        show (length (exportDecls ci)) ++
                                                        start ++ "\n" ++
                                              "\n\n")

start = ""

helpers = "def idris_Prelude_46_Nat_46_toIntNat_58_toIntNat_39__58_0(loc0, loc1, loc2): #Prelude.Nat.toIntNat:toIntNat':0\n  return loc1\n"

sename :: Name -> String
sename n = "idris_" ++ concatMap sechar (showCG n)
  where sechar x | isAlpha x || isDigit x = [x]
                 | otherwise = "_" ++ show (fromEnum x) ++ "_"

var :: Name -> String
var n = sename n

loc :: Int -> String
loc i = "loc" ++ show i

indent :: Int -> String
indent ind = take (ind*2) $ repeat ' '

doCodegen :: (Name, SDecl) -> String
doCodegen (n, SFun _ args i def) = cgFun n args def

--EXPORTS START
cgExport :: ExportIFace -> [String]
cgExport (Export _ffiName _fileName es) = map cgExportDecl es

cgExportDecl :: Export -> String
cgExportDecl (ExportFun fn (FStr en) (FIO ret) argTys)
    = cgExportFun fn en (length argTys)
cgExportDecl _ = ""  -- ignore everything else. Like Data.

--TODO: Real interfaces?
cgExportFun :: Name -> String -> Int -> String
cgExportFun fn en argCnt = "#export: " ++ show fn

--EXPORTS END

shouldSkip :: Name -> Bool
shouldSkip n@(NS _ ns) = any (\x -> elem (str x) [
  -- Skipped namespaces
  "__prim", "prim" --, "Ether"
  ]) ns || elem (showCG n) [
  -- Skipped functions
  "Prelude.Bool.&&",
  "call__IO",
  "Prelude.Bool.ifThenElse",
  "Prelude.Classes.intToBool",
  "mkForeignPrim",
  "Force",
  "Void_case",
  "Void_elim"
  ]
shouldSkip n@(SN _) = not $ elem (showCG n) [
  --"Prelude.Nat.toIntNat:toIntNat':0"
  ]
shouldSkip (UN n) = not $ elem (str n) [
  --Included "special" (really user defined) functions
  "io_return",
  "io_bind"
  ]
shouldSkip n = False -- Hitt på nåt. let s = showCG n in isInfixOf "Ethereum" s || isInfixOf "Prelude" s

cgFun :: Name -> [Name] -> SExp -> String
cgFun n args def
  | shouldSkip n = "#"++ showCG n ++"\n"
  | otherwise    = "def " ++ sename n ++ "("
                    ++ showSep ", " (map (loc . fst) (zip [0..] args)) ++ "): #"++ showCG n ++"\n"
                    ++ cgBody 2 doRet def ++ "\n\n"
  where doRet :: Int -> String -> String -- Return the calculated expression
        doRet ind str = "retVal = " ++ str ++ "\n" ++ indent ind ++ "return retVal\n"

-- cgBody converts the SExp into a chunk of se which calculates the result
-- of an expression, then runs the function on the resulting bit of code.
--
-- We do it this way because we might calculate an expression in a deeply nested
-- case statement, or inside a let, etc, so the assignment/return of the calculated
-- expression itself may happen quite deeply.

cgBody :: Int -> (Int -> String -> String) -> SExp -> String
cgBody ind ret (SV (Glob n)) = indent ind ++ (ret ind $ sename n ++ "()")
cgBody ind ret (SV (Loc i)) = indent ind ++ (ret ind $ loc i)
cgBody ind ret (SApp _ f args)
  | otherwise        = indent ind ++ ret ind ("self." ++ sename f ++ "(" ++
                                   showSep ", " (map cgVar args) ++ ")")
cgBody ind ret (SLet (Loc i) v sc)
   = cgBody ind (\_ x -> loc i ++ " = " ++ x ++ "\n") v ++
     cgBody ind ret sc
cgBody ind ret (SUpdate n e)
   = cgBody ind ret e
cgBody ind ret (SProj e i)
   = indent ind ++ (ret ind $ cgVar e ++ "[" ++ show (i + 1) ++ "]")
cgBody ind ret (SCon _ t n args)
   = indent ind ++ (ret ind $ "[" ++ showSep ","
              (show t : (map cgVar args)) ++ "]")
cgBody ind ret (SCase _ e alts) = cgBody ind ret (SChkCase e alts)
cgBody ind ret (SChkCase e (a:alts))
   = let scr = cgVar e
         scrvar = if any conCase alts || conCase a then scr ++ "[0]" else scr in
         (cgAlt ind ret scr scrvar "if" a) ++ showSep "\n" (map (cgAlt ind ret scr scrvar "elif") alts) ++ "\n"
  where conCase (SConCase _ _ _ _ _) = True
        conCase _ = False
cgBody ind ret (SConst c) = indent ind ++ (ret ind $ cgConst c)
cgBody ind ret (SOp (LExternal (NS (UN t) _)) args) = indent ind ++ cgEthereumPrim ind ret (unpack t) (map cgVar args)
cgBody ind ret (SOp op args) = indent ind ++ (ret ind $ cgOp op (map cgVar args))
cgBody ind ret SNothing = indent ind ++ (ret ind "0 #Nothing")
cgBody ind ret (SError x) = indent ind ++ (ret ind $ "error( " ++ show x ++ ")")
cgBody ind ret (SForeign desc1 desc2 args) = indent ind ++ "ERROR('Unhandled foreign function " ++ show desc1 ++ ", "++ show desc2 ++ ")"

cgFArgs :: [(FDesc,LVar)] -> String
cgFArgs []   = ""
cgFArgs args = "(" ++ intercalate "," (map (cgVar . snd) args) ++ ")"

cgAlt :: Int -> (Int -> String -> String) -> String -> String -> String -> SAlt -> String
cgAlt ind ret scr scrvar f (SConstCase t exp)
   = indent ind ++ (f ++ " " ++ scrvar ++ " == " ++ show t ++ ":\n" ++ cgBody (ind+1) ret exp)
cgAlt ind ret scr scrvar f (SDefaultCase exp)
   = indent ind ++ (f ++ " True:\n" ++ cgBody (ind+1) ret exp)
cgAlt ind ret scr scrvar f (SConCase lv t n args exp)
   = indent ind ++ (f ++ " " ++ scrvar ++ " == " ++ show t ++ ":\n"
             ++ project 1 lv args ++ "\n" ++ cgBody (ind+1) ret exp)
   where project i v [] = "" -- indent (ind+1) ++ "#empty project"
         project i v (n : ns) = indent (ind+1) ++ (loc v ++ " = " ++ scr ++ "[" ++ show i ++ "]\n"
                                  ++ project (i + 1) (v + 1) ns)

cgVar :: LVar -> String
cgVar (Loc i) = loc i
cgVar (Glob n) = var n

cgConst :: Const -> String
cgConst (I i) = show i
cgConst (Ch i) = show (ord i) -- Treat Char as ints, because Se treats them as Strings...
cgConst (BI i) = show i
cgConst (Str s) = show s
cgConst TheWorld = "0 #TheWorld"
cgConst x | isTypeConst x = "0 #TypeConst"
cgConst x = error $ "Constant " ++ show x ++ " not compilable yet"

cgOp :: PrimFn -> [String] -> String
cgOp (LPlus (ATInt _)) [l, r]
     = "(" ++ l ++ " + " ++ r ++ ")"
cgOp (LMinus (ATInt _)) [l, r]
     = "(" ++ l ++ " - " ++ r ++ ")"
cgOp (LTimes (ATInt _)) [l, r]
     = "(" ++ l ++ " * " ++ r ++ ")"
cgOp (LEq (ATInt _)) [l, r]
     = "(" ++ l ++ " == " ++ r ++ ")"
cgOp (LSLt (ATInt _)) [l, r]
     = "(" ++ l ++ " < " ++ r ++ ")"
cgOp (LSLe (ATInt _)) [l, r]
     = "(" ++ l ++ " <= " ++ r ++ ")"
cgOp (LSGt (ATInt _)) [l, r]
     = "(" ++ l ++ " > " ++ r ++ ")"
cgOp (LSGe (ATInt _)) [l, r]
     = "(" ++ l ++ " >= " ++ r ++ ")"
cgOp (LSExt _ _) [x] = x
cgOp op exps = "0 #error(\"OPERATOR " ++ show op ++ " NOT IMPLEMENTED!!!!\")"

cgEthereumPrim :: Int -> (Int -> String -> String) -> String -> [String] -> String
cgEthereumPrim ind ret "prim__value"        args = ret ind "msg.value"
cgEthereumPrim ind ret "prim__selfbalance"  args = ret ind $ "self.balance"
cgEthereumPrim ind ret "prim__balance"      args = ret ind $ head args ++ ".balance"
cgEthereumPrim ind ret "prim__send"         args = ret ind $ head args ++ ".send(" ++ (args !! 1) ++ ")"
cgEthereumPrim ind ret "prim__remainingGas" args = ret ind $ "msg.gas"
cgEthereumPrim ind ret "prim__timestamp"    args = ret ind $ "block.timestamp"
cgEthereumPrim ind ret "prim__coinbase"     args = ret ind $ "block.coinbase"
cgEthereumPrim ind ret "prim__self"         args = ret ind $ "self"
cgEthereumPrim ind ret "prim__sender"       args = ret ind $ "msg.sender"
cgEthereumPrim ind ret "prim__origin"       args = ret ind $ "tx.origin"
cgEthereumPrim ind ret "prim__gasprice"     args = ret ind $ "tx.gasprice"
cgEthereumPrim ind ret "prim__prevhash"     args = ret ind $ "block.prevhash"
cgEthereumPrim ind ret "prim__difficulty"   args = ret ind $ "block.difficulty"
cgEthereumPrim ind ret "prim__blocknumber"  args = ret ind $ "block.number"
cgEthereumPrim ind ret "prim__gaslimit"     args = ret ind $ "block.gaslimit"
cgEthereumPrim ind ret "prim__read"            args = ret ind $ "self.storage[" ++ head args ++ "]"
cgEthereumPrim ind ret "prim__write"           args = ret ind $ "self.storage[" ++ head args ++ "] = " ++ (args !! 1)
cgEthereumPrim ind ret "prim__readMap"         args =
  indent ind ++ "mk = 'idr_' + " ++ head args ++ " + '_' + " ++ (args !! 1) ++ "\n" ++
  indent ind ++ (ret ind "self.storage[mk]")
cgEthereumPrim ind ret "prim__writeMap"         args =
  indent ind ++ "mk = 'idr_' + " ++ head args ++ " + '_' + " ++ (args !! 1) ++ "\n" ++
  ret ind ("self.storage [mk] = " ++ (args !! 2))

cgEthereumPrim ind ret n _ =  "ERROR('Unimplemented cgEthereumPrim\')"

cgName :: Name -> String
cgName (UN t) = show t
cgName _ = "UNIMPLEMENTED CASE in cgName"

