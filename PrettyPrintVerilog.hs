{-# OPTIONS_GHC -XStandaloneDeriving #-}

import Target
import Data.List
import Data.List.Split
import Control.Monad.State.Lazy
import qualified Data.HashMap.Lazy as H


deriving instance Show T
deriving instance Show Target.Word
deriving instance Show UniBoolOp
deriving instance Show CABoolOp
deriving instance Show UniBitOp
deriving instance Show CABitOp

deriving instance Eq T

ppVecLen :: Int -> String
ppVecLen n = "[" ++ show (n-1) ++ ":0]"

finToInt :: T -> Int
finToInt (F1 _) = 0
finToInt (FS _ x) = Prelude.succ (finToInt x)

intToFin :: Int -> Int -> T
intToFin m 0 = F1 (m-1)
intToFin m n = FS (m-1) (intToFin (m-1) (n-1))

getFins :: Int -> [T]
getFins m = foldr (\n l -> intToFin m n : l) [] [0 .. (m-1)]

wordToList :: Target.Word -> [Bool]
wordToList WO = []
wordToList (WS b _ w) = b : wordToList w

ppTypeVec :: Kind -> Int -> (Kind, [Int])
ppTypeVec k@(Array i' k') i =
  let (k'', is) = ppTypeVec k' i'
  in (k', i : is)
ppTypeVec k i = (k, i : [])

ppTypeName :: Kind -> String
ppTypeName k =
  case ppTypeVec k 0 of
    (Struct _ _ _, _) -> "struct packed"
    (_, _) -> "logic"

ppDeclType :: String -> Kind -> String
ppDeclType s k = ppTypeName k ++ ppType k ++ " " ++ s

ppName :: String -> String
ppName s = intercalate "$" (Data.List.map (\x -> ppDottedName x) (splitOneOf "$#" s))
  {-
  if elem '.' s
  then intercalate "$" (case splitOneOf ".#" s of
                          x : y : xs -> x : y : xs
                          ys -> ys)
  else Data.List.map (\x -> case x of
                         '#' -> '$'
                         c -> c) s
-}



ppType :: Kind -> String
ppType Bool = ""
ppType (Bit i) = if i > 0
                      then "[" ++ show (i-1) ++ ":0]"
                      else ""
ppType v@(Array i k) =
  let (k', is) = ppTypeVec k i
  in case k' of
       Struct _ _ _ -> ppType k' ++ concatMap ppVecLen is
       _ -> concatMap ppVecLen is ++ ppType k'
ppType (Struct n fk fs) =
  "{" ++ concatMap (\i -> ' ' : ppDeclType (ppName $ fs i) (fk i) ++ ";") (getFins n) ++ "}"

ppDottedName :: String -> String
ppDottedName s =
  case splitOn "." s of
    x : y : nil -> y ++ "$" ++ x
    x : nil -> x


ppPrintVar :: (String, [Int]) -> String
ppPrintVar (s, vs) = ppName $ s ++ concatMap (\v -> '#' : show v) vs

ppWord :: [Bool] -> String
ppWord [] = []
ppWord (b : bs) = (if b then '1' else '0') : ppWord bs

ppConst :: ConstT -> String
ppConst (ConstBool b) = if b then "1'b1" else "1'b0"
ppConst (ConstBit sz w) = if sz == 0 then "1'b0" else show sz ++ "\'b" ++ ppWord (reverse $ wordToList w)
ppConst (ConstArray n k fv) = '{' : intercalate ", " (Data.List.map ppConst (Data.List.map fv (getFins n))) ++ "}"
ppConst (ConstStruct n fk fs fv) = '{' : intercalate ", " (Data.List.map ppConst (Data.List.map fv (getFins n))) ++ "}"

ppRtlExpr :: String -> RtlExpr -> State (H.HashMap String (Int, Kind)) String
ppRtlExpr who e =
  case e of
    RtlReadReg k s -> return (ppName s)
    RtlReadWire k var -> return $ ppPrintVar var
    RtlConst k c -> return $ ppConst c
    RtlUniBool Neg e -> uniExpr "~" e
    RtlCABool And es -> listExpr "&" es "1'b1"
    RtlCABool Or es -> listExpr "|" es "1'b0"
    RtlCABool Xor es -> listExpr "^" es "1'b0"
    RtlUniBit _ _ (Inv _) e -> uniExpr "~" e
    RtlUniBit _ _ (UAnd _) e -> uniExpr "&" e
    RtlUniBit _ _ (UOr _) e -> uniExpr "|" e
    RtlUniBit _ _ (UXor _) e -> uniExpr "^" e
    RtlUniBit sz retSz (TruncLsb lsb msb) e -> createTrunc (Bit sz) e (retSz - 1) 0
    RtlUniBit sz retSz (TruncMsb lsb msb) e -> createTrunc (Bit sz) e (sz - 1) lsb
    RtlCABit n Add es -> listExpr "+" es (show n ++ "'b0")
    RtlCABit n Mul es -> listExpr "*" es (show n ++ "'b1")
    RtlCABit n Band es -> listExpr "&" es (show n ++ "'b" ++ replicate n '1')
    RtlCABit n Bor es -> listExpr "|" es (show n ++ "'b0")
    RtlCABit n Bxor es -> listExpr "^" es (show n ++ "'b0")
    RtlBinBit _ _ _ (Sub _) e1 e2 -> binExpr e1 "-" e2
    RtlBinBit _ _ _ (Div _) e1 e2 -> binExpr e1 "/" e2
    RtlBinBit _ _ _ (Rem _) e1 e2 -> binExpr e1 "%" e2
    RtlBinBit _ _ _ (Sll _ _) e1 e2 -> binExpr e1 "<<" e2
    RtlBinBit _ _ _ (Srl _ _) e1 e2 -> binExpr e1 ">>" e2
    RtlBinBit _ _ _ (Sra _ _) e1 e2 ->
      do
        x1 <- ppRtlExpr who e1
        x2 <- ppRtlExpr who e2
        return $ "($signed(" ++ x1 ++ ") >>> " ++ x2 ++ ")"
    RtlBinBit _ _ _ (Concat _ n) e1 e2 ->
      if n /= 0
      then
        do
          x1 <- ppRtlExpr who e1
          x2 <- ppRtlExpr who e2
          return $ '{' : x1 ++ ", " ++ x2 ++ "}"
      else
        do
          x1 <- ppRtlExpr who e1
          return x1
    RtlBinBitBool _ _ (_) e1 e2 -> binExpr e1 "<" e2
    RtlITE _ p e1 e2 -> triExpr p "?" e1 ":" e2
    RtlEq _ e1 e2 -> binExpr e1 "==" e2
    RtlReadStruct num fk fs e i ->
      do
        new <- optionAddToTrunc (Struct num fk fs) e
        return $ new ++ '.' : (fs i)
    RtlBuildStruct num fk fs es ->
      do
        strs <- mapM (ppRtlExpr who) (Data.List.map es (getFins num))
        return $ '{': intercalate ", " strs ++ "}"
    RtlReadArray n k vec idx ->
      do
        xidx <- ppRtlExpr who idx
        xvec <- ppRtlExpr who vec
        new <- optionAddToTrunc (Array n k) vec
        return $ new ++ '[' : xidx ++ "]"
    RtlReadArrayConst n k vec idx ->
      do
        let xidx = finToInt idx
        xvec <- ppRtlExpr who vec
        new <- optionAddToTrunc (Array n k) vec
        return $ new ++ '[' : show xidx ++ "]"
    RtlBuildArray n k fv ->
      do
        strs <- mapM (ppRtlExpr who) (reverse $ Data.List.map fv (getFins n))
        return $ '{': intercalate ", " strs ++ "}"
  where
    optionAddToTrunc :: Kind -> RtlExpr -> State (H.HashMap String (Int, Kind)) String
    optionAddToTrunc k e =
      case e of
        RtlReadReg k s -> return $ ppName s
        RtlReadWire k var -> return $ ppPrintVar var
        _ -> do
          x <- ppRtlExpr who e
          new <- addToTrunc k x
          return new
    createTrunc :: Kind -> RtlExpr -> Int -> Int -> State (H.HashMap String (Int, Kind)) String
    createTrunc k e msb lsb =
      do
        new <- optionAddToTrunc k e
        return $ new ++ '[' : show msb ++ ':' : show lsb ++ "]"
    addToTrunc :: Kind -> String -> State (H.HashMap String (Int, Kind)) String
    addToTrunc kind s =
      do
        x <- get
        case H.lookup s x of
          Just (pos, _) -> return $ "_trunc$" ++ who ++ "$" ++ show pos
          Nothing ->
            do
              put (H.insert s (H.size x, kind) x)
              return $ "_trunc$" ++ who ++ "$" ++ show (H.size x)
    uniExpr op e =
      do
        x <- ppRtlExpr who e
        return $ '(' : " " ++ op ++ " " ++ x ++ ")"
    listExpr' op es init =
      case es of
        e : es' -> do
                     x <- ppRtlExpr who e
                     xs <- listExpr' op es' init
                     return $ x ++ " " ++ op ++ " " ++ xs
        [] -> return init
    listExpr op es init =
      do
        xs <- listExpr' op es init
        return $ '(' : xs ++ ")"
    binExpr e1 op e2 =
      do
        x1 <- ppRtlExpr who e1
        x2 <- ppRtlExpr who e2
        return $ '(' : x1 ++ " " ++ op ++ " " ++ x2 ++ ")"
    triExpr e1 op1 e2 op2 e3 =
      do
        x1 <- ppRtlExpr who e1
        x2 <- ppRtlExpr who e2
        x3 <- ppRtlExpr who e3
        return $ '(' : x1 ++ " " ++ op1 ++ " " ++ x2 ++ " " ++ op2 ++ " " ++ x3 ++ ")"

ppRfInstance :: (((String, [(String, Bool)]), String), (((Int, Kind)), ConstT)) -> String
ppRfInstance (((name, reads), write), ((idxType, dataType), _)) =
  "  " ++ ppName name ++ " " ++
  ppName name ++ "$inst(.CLK(CLK), .RESET_N(RESET_N), ." ++
  concatMap (\(read, _) ->
               ppName read ++ "$_guard(" ++ ppName read ++ "$_guard), ." ++
               ppName read ++ "$_enable(" ++ ppName read ++ "$_enable), ." ++
               ppName read ++ "$_argument(" ++ ppName read ++ "$_argument), ." ++
               ppName read ++ "$_return(" ++ ppName read ++ "$_return), .") reads ++
  ppName write ++ "$_guard(" ++ ppName write ++ "$_guard), ." ++
  ppName write ++ "$_enable(" ++ ppName write ++ "$_enable), ." ++
  ppName write ++ "$_argument(" ++ ppName write ++ "$_argument));\n\n"


ppRfModule :: (((String, [(String, Bool)]), String), ((Int, Kind), ConstT)) -> String
ppRfModule (((name, reads), write), ((idxType, dataType), init)) =
  "module " ++ ppName name ++ "(\n" ++
  concatMap (\(read, _) ->
               "  output " ++ ppDeclType (ppName read ++ "$_guard") Bool ++ ",\n" ++
              "  input " ++ ppDeclType (ppName read ++ "$_enable") Bool ++ ",\n" ++
              "  input " ++ ppDeclType (ppName read ++ "$_argument") (Bit idxType) ++ ",\n" ++
              "  output " ++ ppDeclType (ppName read ++ "$_return") dataType ++ ",\n") reads ++
  "  output " ++ ppDeclType (ppName write ++ "$_guard") Bool ++ ",\n" ++
  "  input " ++ ppDeclType (ppName write ++ "$_enable") Bool ++ ",\n" ++
  "  input " ++ ppDeclType (ppName write ++ "$_argument")
  (Struct 2 (\i -> if i == F1 1 then (Bit idxType) else if i == FS 1 (F1 0) then dataType else (Bit 0)) (\i -> if i == F1 1 then "addr" else if i == FS 1 (F1 0) then "data" else "")) ++ ",\n" ++
  "  input logic CLK,\n" ++
  "  input logic RESET_N\n" ++
  ");\n" ++
  --"  " ++ ppDeclType (ppName name ++ "$_data") dataType ++ "[0:" ++ show (2^idxType - 1) ++ "];\n" ++
  "  " ++ ppDeclType (ppName name ++ "$_data") (Bit (Target.size dataType)) ++ "[0:" ++ show (2^idxType - 1) ++ "];\n" ++
  "  initial begin\n" ++
  -- "    " ++ ppName name ++ "$_data = " ++ '\'' : ppConst init ++ ";\n" ++
  "    $readmemb(" ++ "\"" ++ ppName name ++ ".mem" ++ "\", " ++ ppName name ++ "$_data, 0, " ++ show (2^idxType - 1) ++ ");\n" ++
  "  end\n" ++
  concatMap (\(read, bypass) ->
               "  assign " ++ ppName read ++ "$_guard = 1'b1;\n" ++
              "  assign " ++ ppName read ++ "$_return = " ++
              if bypass
              then ppName write ++ "$_enable && " ++ ppName write ++ "$_argument.addr == " ++
                   ppName read ++ "$_argument ? " ++ ppName write ++ "$_data : "
              else "" ++ ppName name ++ "$_data[" ++ ppName read ++ "$_argument];\n") reads ++
  "  assign " ++ ppName write ++ "$_guard = 1'b1;\n" ++
  "  always@(posedge CLK) begin\n" ++
  "    if(" ++ ppName write ++ "$_enable) begin\n" ++
  "      " ++ ppName name ++ "$_data[" ++ ppName write ++ "$_argument.addr] <= " ++ ppName write ++ "$_argument.data;\n" ++
  "    end\n" ++
  "  end\n" ++
  "endmodule\n\n"

removeDups :: Eq a => [(a, b)] -> [(a, b)]
removeDups = nubBy (\(a, _) (b, _) -> a == b)

ppRtlInstance :: RtlModule -> String
ppRtlInstance m@(Build_RtlModule regFs ins' outs' regInits' regWrites' assigns' sys') =
  "  _design _designInst(.CLK(CLK), .RESET_N(RESET_N)" ++
  concatMap (\(nm, ty) -> ", ." ++ ppPrintVar nm ++ '(' : ppPrintVar nm ++ ")") (removeDups ins' ++ removeDups outs') ++ ");\n"

ppBitFormat :: BitFormat -> String
ppBitFormat Binary = "b"
ppBitFormat Decimal = "d"
ppBitFormat Hex = "x"

ppFullBitFormat :: FullBitFormat -> String
ppFullBitFormat (sz, f) = "%" ++ show sz ++ ppBitFormat f

ppRtlSys :: RtlSysT -> State (H.HashMap String (Int, Kind)) String
ppRtlSys (RtlDispString s) = return $ "        $write(\"" ++ s ++ "\");\n"
ppRtlSys (RtlDispBool e f) = do
  s <- ppRtlExpr "sys" e
  return $ "        $write(\"" ++ ppFullBitFormat f ++ "\", " ++ s ++ ");\n"
ppRtlSys (RtlDispBit _ e f) = do
  s <- ppRtlExpr "sys" e
  return $ "        $write(\"" ++ ppFullBitFormat f ++ "\", " ++ s ++ ");\n"
ppRtlSys (RtlDispStruct n fk fs fv ff) = do
  rest <- mapM (\i -> ppRtlExpr "sys" (RtlReadStruct n fk fs fv i)) (getFins n)
  return $ "        $write(\"{" ++ Data.List.concat (Data.List.map (\i -> fs i ++ ":=" ++ ppFullBitFormat (ff i) ++ "; ") (getFins n)) ++ "}\", " ++ Data.List.concat rest ++ ");\n"
ppRtlSys (RtlDispArray n k v f) = do
  rest <- mapM (\i -> ppRtlExpr "sys" (RtlReadArray n k v (RtlConst k (ConstBit (log2_up n) (natToWord (log2_up n) i))))) [0 .. (n-1)]
  return $ "        $write(\"[" ++ Data.List.concat (Data.List.map (\i -> show i ++ ":=" ++ ppFullBitFormat f ++ "; ") [0 .. (n-1)]) ++ "]\", " ++ Data.List.concat rest ++ ");\n"
  
  
ppRtlModule :: RtlModule -> String
ppRtlModule m@(Build_RtlModule regFs ins' outs' regInits' regWrites' assigns' sys') =
  "module _design(\n" ++
  concatMap (\(nm, ty) -> "  input " ++ ppDeclType (ppPrintVar nm) ty ++ ",\n") ins ++ "\n" ++
  concatMap (\(nm, ty) -> "  output " ++ ppDeclType (ppPrintVar nm) ty ++ ",\n") outs ++ "\n" ++
  "  input CLK,\n" ++
  "  input RESET_N\n" ++
  ");\n" ++
  concatMap (\(nm, (ty, init)) -> "  " ++ ppDeclType (ppName nm) ty ++ ";\n") regInits ++ "\n" ++

  concatMap (\(nm, (ty, expr)) -> "  " ++ ppDeclType (ppPrintVar nm) ty ++ ";\n") assigns ++ "\n" ++

  concatMap (\(sexpr, (pos, ty)) -> "  " ++ ppDeclType ("_trunc$wire$" ++ show pos) ty ++ ";\n") assignTruncs ++ "\n" ++
  concatMap (\(sexpr, (pos, ty)) -> "  " ++ ppDeclType ("_trunc$reg$" ++ show pos) ty ++ ";\n") regTruncs ++ "\n" ++
  concatMap (\(sexpr, (pos, ty)) -> "  " ++ ppDeclType ("_trunc$sys$" ++ show pos) ty ++ ";\n") sysTruncs ++ "\n" ++

  concatMap (\(sexpr, (pos, ty)) -> "  assign " ++ "_trunc$wire$" ++ show pos ++ " = " ++ sexpr ++ ";\n") assignTruncs ++ "\n" ++
  concatMap (\(sexpr, (pos, ty)) -> "  assign " ++ "_trunc$reg$" ++ show pos ++ " = " ++ sexpr ++ ";\n") regTruncs ++ "\n" ++
  concatMap (\(sexpr, (pos, ty)) -> "  assign " ++ "_trunc$sys$" ++ show pos ++ " = " ++ sexpr ++ ";\n") sysTruncs ++ "\n" ++
  
  concatMap (\(nm, (ty, sexpr)) -> "  assign " ++ ppPrintVar nm ++ " = " ++ sexpr ++ ";\n") assignExprs ++ "\n" ++
  
  "  always @(posedge CLK) begin\n" ++
  "    if(!RESET_N) begin\n" ++
  concatMap (\(nm, (ty, init)) -> case init of
                                    Nothing -> ""
                                    Just init' -> "      " ++ ppName nm ++ " <= " ++ ppConst init' ++ ";\n") regInits ++
  "    end\n" ++
  "    else begin\n" ++
  concatMap (\(nm, (ty, sexpr)) -> "      " ++ ppName nm ++ " <= " ++ sexpr ++ ";\n") regExprs ++
  concatMap (\(pred, sys) -> "      if(" ++ pred ++ ") begin\n" ++ sys ++ "      end\n") sys ++
  "    end\n" ++
  "  end\n" ++
  "endmodule\n\n"
  where
    ins = removeDups ins'
    outs = removeDups outs'
    regInits = removeDups regInits'
    regWrites = removeDups regWrites'
    assigns = removeDups assigns'
    convAssigns =
      mapM (\(nm, (ty, expr)) ->
              do
                s <- ppRtlExpr "wire" expr
                return (nm, (ty, s))) assigns
    convRegs =
      mapM (\(nm, (ty, expr)) ->
              do
                s <- ppRtlExpr "reg" expr
                return (nm, (ty, s))) regWrites
    (assignExprs, assignTruncs') = runState convAssigns H.empty
    (regExprs, regTruncs') = runState convRegs H.empty
    assignTruncs = H.toList assignTruncs'
    regTruncs = H.toList regTruncs'
    convSys = mapM(\(pred, listSys) ->
                      do
                        predExpr <- ppRtlExpr "sys" pred
                        s <- mapM ppRtlSys listSys
                        return $ (predExpr, Data.List.concat s)) sys'
    (sys, sysTruncs') = runState convSys H.empty
    sysTruncs = H.toList sysTruncs'

ppGraph :: [(String, [String])] -> String
ppGraph x = case x of
              [] -> ""
              (a, b) : ys -> "(" ++ show a ++ ", " ++ show b ++ ", " ++ show (Data.List.length b) ++ "),\n" ++ ppGraph ys


maxOutEdge :: [(String, [String])] -> Int
maxOutEdge x = case x of
                 [] -> 0
                 (a, b) : ys -> Prelude.max (Data.List.length b) (maxOutEdge ys)

sumOutEdge :: [(String, [String])] -> Int
sumOutEdge x = case x of
                 [] -> 0
                 (a, b) : ys -> Data.List.length b + sumOutEdge ys

ppTopModule :: RtlModule -> String
ppTopModule m@(Build_RtlModule regFs ins' outs' regInits' regWrites' assigns' sys') =
  concatMap ppRfModule regFs ++ ppRtlModule m ++
  "module top(\n" ++
  concatMap (\(nm, ty) -> "  input " ++ ppDeclType (ppPrintVar nm) ty ++ ",\n") ins ++ "\n" ++
  concatMap (\(nm, ty) -> "  output " ++ ppDeclType (ppPrintVar nm) ty ++ ",\n") outs ++ "\n" ++
  "  input CLK,\n" ++
  "  input RESET_N\n" ++
  ");\n" ++
  concatMap (\(nm, ty) -> "  " ++ ppDeclType (ppPrintVar nm) ty ++ ";\n") insAll ++ "\n" ++
  concatMap (\(nm, ty) -> "  " ++ ppDeclType (ppPrintVar nm) ty ++ ";\n") outsAll ++ "\n" ++
  concatMap ppRfInstance regFs ++
  ppRtlInstance m ++
  "endmodule\n"
  where
    insAll = removeDups ins'
    outsAll = removeDups outs'
    ins = Data.List.filter filtCond insAll
    outs = Data.List.filter filtCond outsAll
    badRead x read = x == read ++ "#_g" || x == read ++ "#_en" || x == read ++ "#_arg" || x == read ++ "#_ret"
    badReads x reads = foldl (\accum (v, _) -> badRead x v || accum) False reads
    filtCond ((x, _), _) = case Data.List.find (\((((_, reads), write), (_, _))) ->
                                                  badReads x reads ||
                                                  {-
                                                  x == read ++ "#_g" ||
                                                  x == read ++ "#_en" ||
                                                  x == read ++ "#_arg" ||
                                                  x == read ++ "#_ret" ||
                                                  -}
                                                  x == write ++ "#_g" ||
                                                  x == write ++ "#_en" ||
                                                  x == write ++ "#_arg" ||
                                                  x == write ++ "#_ret") regFs of
                          Nothing -> True
                          _ -> False

printDiff :: [(String, [String])] -> [(String, [String])] -> IO ()
printDiff (x:xs) (y:ys) =
  do
    if x == y
    then printDiff xs ys
    else putStrLn $ (show x) ++ " " ++ (show y)
printDiff [] [] = return ()
printDiff _ _ = putStrLn "Wrong lengths"

ppConstMem :: ConstT -> String
ppConstMem (ConstBool b) = if b then "1" else "0"
ppConstMem (ConstBit sz w) = if sz == 0 then "0" else ppWord (reverse $ wordToList w)
ppConstMem (ConstStruct num fk fs fv) = Data.List.concatMap ppConstMem (Data.List.map fv (getFins num))
ppConstMem (ConstArray num k fv) = Data.List.concatMap ppConstMem (reverse $ Data.List.map fv (getFins num))

ppRfFile :: (((String, [(String, Bool)]), String), ((Int, Kind), ConstT)) -> String
ppRfFile (((name, reads), write), ((idxType, dataType), ConstArray num k fv)) =
  concatMap (\v -> ppConstMem v ++ "\n") (reverse $ Data.List.map fv (getFins num)) ++ "\n"

ppRfName :: (((String, [(String, Bool)]), String), ((Int, Kind), ConstT)) -> String
ppRfName (((name, reads), write), ((idxType, dataType), ConstArray num k fv)) = ppName name ++ ".mem"
  
main =
  do
    putStrLn $ ppTopModule fpu
    let (Build_RtlModule regFs _ _ _ _ _ _) = fpu in
      mapM_ (\rf -> writeFile (ppRfName rf) (ppRfFile rf)) regFs