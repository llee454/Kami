{-# OPTIONS_GHC -XStandaloneDeriving #-}

import qualified Target as T
import Data.List
import Data.List.Split
import Control.Monad.State.Lazy
import qualified Data.HashMap.Lazy as H
import Debug.Trace

instance Show T.Coq_word where
  show w = show (T.wordToNat 0 w)

intToFin :: Int -> Int -> T.Coq_t
intToFin m 0 = T.F1 (m-1)
intToFin m n = T.FS (m-1) (intToFin (m-1) (n-1))

deriving instance Eq T.Coq_t

ppDealSize0 :: T.Kind -> String -> String -> String
ppDealSize0 ty def str = if T.size ty == 0 then def else str

ppVecLen :: Int -> String
ppVecLen n = "[" ++ show (n-1) ++ ":0]"

finToInt :: T.Coq_t -> Int
finToInt (T.F1 _) = 0
finToInt (T.FS _ x) = Prelude.succ (finToInt x)

instance Show T.Coq_t where
  show f = show (finToInt f)

wordToList :: T.Coq_word -> [Bool]
wordToList T.WO = []
wordToList (T.WS b _ w) = b : wordToList w

ppTypeVec :: T.Kind -> Int -> (T.Kind, [Int])
ppTypeVec k@(T.Array i' k') i =
  let (k'', is) = ppTypeVec k' i'
  in (k', i : is)
ppTypeVec k i = (k, i : [])

ppTypeName :: T.Kind -> String
ppTypeName k =
  case ppTypeVec k 0 of
    (T.Struct _ _ _, _) -> "struct packed"
    (_, _) -> "logic"

ppDeclType :: String -> T.Kind -> String
ppDeclType s k = ppTypeName k ++ ppType k ++ " " ++ s

ppName :: String -> String
ppName s = intercalate "$" (Data.List.map (\x -> ppDottedName x) (splitOneOf "$#?" s))
  {-
  if elem '.' s
  then intercalate "$" (case splitOneOf ".#" s of
                          x : y : xs -> x : y : xs
                          ys -> ys)
  else Data.List.map (\x -> case x of
                         '#' -> '$'
                         c -> c) s
-}



ppType :: T.Kind -> String
ppType T.Bool = ""
ppType (T.Bit i) = "[" ++ show (i-1) ++ ":0]"
  -- if i > 0
  -- then "[" ++ show (i-1) ++ ":0]"
  -- else ""
ppType v@(T.Array i k) =
  let (k', is) = ppTypeVec k i
  in case k' of
       T.Struct _ _ _ -> ppType k' ++ concatMap ppVecLen is
       _ -> concatMap ppVecLen is ++ ppType k'
ppType (T.Struct n fk fs) =
  "{" ++ concatMap (\i -> ppDealSize0 (fk i) "" (' ' : ppDeclType (ppName $ fs i) (fk i) ++ ";")) (T.getFins n) ++ "}"

ppDottedName :: String -> String
ppDottedName s =
  case splitOn "." s of
    x : y : nil -> y ++ "$" ++ x
    x : nil -> x


ppPrintVar :: (String, Int) -> String
ppPrintVar (s, v) = ppName $ s ++ if v /= 0 then '#' : show v else []

ppWord :: [Bool] -> String
ppWord [] = []
ppWord (b : bs) = (if b then '1' else '0') : ppWord bs

ppConst :: T.ConstT -> String
ppConst (T.ConstBool b) = if b then "1'b1" else "1'b0"
ppConst (T.ConstBit sz w) = show sz ++ "\'b" ++ ppWord (reverse $ wordToList w)
ppConst (T.ConstArray n k fv) = '{' : intercalate ", " (Data.List.map ppConst (Data.List.map fv (T.getFins n))) ++ "}"
ppConst (T.ConstStruct n fk fs fv) = '{' : intercalate ", " (snd (unzip (Data.List.filter (\(k,e) -> T.size k /= 0) (zip (Data.List.map fk (T.getFins n)) (Data.List.map ppConst (Data.List.map fv (T.getFins n))))))) ++ "}"


ppRtlExpr :: String -> T.RtlExpr -> State (H.HashMap String (Int, T.Kind)) String
ppRtlExpr who e =
  case e of
    T.RtlReadReg k s -> return $ ppDealSize0 k "0" (ppName s)
    T.RtlReadWire k var -> return $ ppDealSize0 k "0" (ppPrintVar var)
    T.RtlConst k c -> return $ ppDealSize0 k "0" (ppConst c)
    T.RtlUniBool T.Neg e -> uniExpr "~" e
    T.RtlCABool T.And es -> listExpr "&" es "1'b1"
    T.RtlCABool T.Or es -> listExpr "|" es "1'b0"
    T.RtlCABool T.Xor es -> listExpr "^" es "1'b0"
    T.RtlUniBit _ _ (T.Inv _) e -> uniExpr "~" e
    T.RtlUniBit _ _ (T.UAnd _) e -> uniExpr "&" e
    T.RtlUniBit _ _ (T.UOr _) e -> uniExpr "|" e
    T.RtlUniBit _ _ (T.UXor _) e -> uniExpr "^" e
    T.RtlUniBit sz retSz (T.TruncLsb lsb msb) e -> createTrunc (T.Bit sz) e (retSz - 1) 0
    T.RtlUniBit sz retSz (T.TruncMsb lsb msb) e -> createTrunc (T.Bit sz) e (sz - 1) lsb
    T.RtlCABit n T.Add es -> listExpr "+" es (show n ++ "'b0")
    T.RtlCABit n T.Mul es -> listExpr "*" es (show n ++ "'b1")
    T.RtlCABit n T.Band es -> listExpr "&" es (show n ++ "'b" ++ Data.List.replicate n '1')
    T.RtlCABit n T.Bor es -> listExpr "|" es (show n ++ "'b0")
    T.RtlCABit n T.Bxor es -> listExpr "^" es (show n ++ "'b0")
    T.RtlBinBit _ _ _ (T.Sub _) e1 e2 -> binExpr e1 "-" e2
    T.RtlBinBit _ _ _ (T.Div _) e1 e2 -> binExpr e1 "/" e2
    T.RtlBinBit _ _ _ (T.Rem _) e1 e2 -> binExpr e1 "%" e2
    T.RtlBinBit _ _ _ (T.Sll _ _) e1 e2 -> binExpr e1 "<<" e2
    T.RtlBinBit _ _ _ (T.Srl _ _) e1 e2 -> binExpr e1 ">>" e2
    T.RtlBinBit _ _ _ (T.Sra n m) e1 e2 ->
      do
        x1 <- ppRtlExpr who e1
        x2 <- ppRtlExpr who e2
        new <- addToTrunc (T.Bit n) ("($signed(" ++ x1 ++ ") >>> " ++ x2 ++ ")")
        return $ new
        -- return $ "($signed(" ++ x1 ++ ") >>> " ++ x2 ++ ")"
    T.RtlBinBit _ _ _ (T.Concat m n) e1 e2 ->
      case (m, n) of
        (0, 0)   -> return $ "0"
        (m', 0)  -> do
          x1 <- ppRtlExpr who e1
          return x1
        (0, n')  -> do
          x2 <- ppRtlExpr who e2
          return x2
        (m', n') -> do
          x1 <- ppRtlExpr who e1
          x2 <- ppRtlExpr who e2
          return $ '{' : x1 ++ ", " ++ x2 ++ "}"
      -- if n /= 0
      -- then
      --   do
      --     x1 <- ppRtlExpr who e1
      --     x2 <- ppRtlExpr who e2
      --     return $ '{' : x1 ++ ", " ++ x2 ++ "}"
      -- else
      --   do
      --     x1 <- ppRtlExpr who e1
      --     return x1
    T.RtlBinBitBool _ _ (_) e1 e2 -> binExpr e1 "<" e2
    T.RtlITE _ p e1 e2 -> triExpr p "?" e1 ":" e2
    T.RtlEq _ e1 e2 -> binExpr e1 "==" e2
    T.RtlReadStruct num fk fs e i ->
      do
        new <- optionAddToTrunc (T.Struct num fk fs) e
        return $ new ++ '.' : ppName (fs i)
    T.RtlBuildStruct num fk fs es ->
      do
        strs <- mapM (ppRtlExpr who) (filterKind0 num fk es)  -- (Data.List.map es (getFins num))
        return $ '{': intercalate ", " strs ++ "}"
    T.RtlReadArray n k vec idx ->
      do
        xidx <- ppRtlExpr who idx
        xvec <- ppRtlExpr who vec
        new <- optionAddToTrunc (T.Array n k) vec
        return $ new ++ '[' : xidx ++ "]"
    T.RtlReadArrayConst n k vec idx ->
      do
        let xidx = finToInt idx
        xvec <- ppRtlExpr who vec
        new <- optionAddToTrunc (T.Array n k) vec
        return $ new ++ '[' : show xidx ++ "]"
    T.RtlBuildArray n k fv ->
      do
        strs <- mapM (ppRtlExpr who) (reverse $ Data.List.map fv (T.getFins n))
        return $ if T.size k == 0 || n == 0 then "0" else '{': intercalate ", " strs ++ "}"
  where
    filterKind0 num fk es = snd (unzip (Data.List.filter (\(k,e) -> T.size k /= 0) (zip (Data.List.map fk (T.getFins num)) (Data.List.map es (T.getFins num)))))
    optionAddToTrunc :: T.Kind -> T.RtlExpr -> State (H.HashMap String (Int, T.Kind)) String
    optionAddToTrunc k e =
      case e of
        T.RtlReadReg k s -> return $ case k of
                                     T.Bit 0 -> "0"
                                     _ -> ppName s
        T.RtlReadWire k var -> return $ case k of
                                        T.Bit 0 -> "0"
                                        _ -> ppPrintVar var
        _ -> do
          x <- ppRtlExpr who e
          new <- addToTrunc k x
          return new
    createTrunc :: T.Kind -> T.RtlExpr -> Int -> Int -> State (H.HashMap String (Int, T.Kind)) String
    createTrunc k e msb lsb =
      do
        new <- optionAddToTrunc k e
        return $ new ++ '[' : show msb ++ ':' : show lsb ++ "]"
    addToTrunc :: T.Kind -> String -> State (H.HashMap String (Int, T.Kind)) String
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

ppRfInstance :: T.RtlRegFileBase -> String
ppRfInstance (rf@(T.Build_RtlRegFileBase isWrMask num name reads write idxNum dataType init)) =
  "  " ++ ppName name ++ " " ++
  ppName name ++ "$_inst(.CLK(CLK), .RESET(RESET), " ++
  (case reads of
     T.RtlAsync readLs ->
       concatMap (\(read, _) ->
                    ("." ++ ppName read ++ "$_enable(" ++ ppName read ++ "$_enable), ") ++
                    (ppDealSize0 (T.Bit (T._Nat__log2_up idxNum)) "" ("." ++ ppName read ++ "$_argument(" ++ ppName read ++ "$_argument), ")) ++
                    ppDealSize0 (T.Array num dataType) "" ("." ++ ppName read ++ "$_return(" ++ ppName read ++ "$_return), ")) readLs
     T.RtlSync isAddr readLs ->
       concatMap (\(T.Build_RtlSyncRead (T.Build_SyncRead readRq readRs _) _ _) ->
                    ("." ++ ppName readRq ++ "$_enable(" ++ ppName readRq ++ "$_enable), ") ++
                    (ppDealSize0 (T.Bit (T._Nat__log2_up idxNum)) "" ("." ++ ppName readRq ++ "$_argument(" ++ ppName readRq ++ "$_argument), ")) ++
                    ("." ++ ppName readRs ++ "$_enable(" ++ ppName readRs ++ "$_enable), ") ++
                    ppDealSize0 (T.Array num dataType) "" ("." ++ ppName readRs ++ "$_return(" ++ ppName readRs ++ "$_return), ")) readLs) ++
  ("." ++ ppName write ++ "$_enable(" ++ ppName write ++ "$_enable), ") ++
  ("." ++ ppName write ++ "$_argument(" ++ ppName write ++ "$_argument)") ++
  ");\n\n"

ppRfModule :: T.RtlRegFileBase -> String
ppRfModule (rf@(T.Build_RtlRegFileBase isWrMask num name reads write idxNum dataType init)) =
  let writeType = if isWrMask then T.coq_WriteRqMask idxNum num dataType else T.coq_WriteRq idxNum (T.Array num dataType) in
  "module " ++ ppName name ++ "(\n" ++
  (case reads of
     T.RtlAsync readLs ->
       concatMap (\(read, _) ->
                    ("  input " ++ ppDeclType (ppName read ++ "$_enable") T.Bool ++ ",\n") ++
                   (ppDealSize0 (T.Bit (T._Nat__log2_up idxNum)) "" ("  input " ++ ppDeclType (ppName read ++ "$_argument") (T.Bit (T._Nat__log2_up idxNum)) ++ ",\n")) ++
                   ppDealSize0 (T.Array num dataType) "" ("  output " ++ ppDeclType (ppName read ++ "$_return") (T.Array num dataType) ++ ",\n")) readLs
     T.RtlSync isAddr readLs ->
       concatMap (\(T.Build_RtlSyncRead (T.Build_SyncRead readRq readRs _) _ _) ->
                    ("  input " ++ ppDeclType (ppName readRq ++ "$_enable") T.Bool ++ ",\n") ++
                   (ppDealSize0 (T.Bit (T._Nat__log2_up idxNum)) "" ("  input " ++ ppDeclType (ppName readRq ++ "$_argument") (T.Bit (T._Nat__log2_up idxNum)) ++ ",\n")) ++
                    ("  input " ++ ppDeclType (ppName readRs ++ "$_enable") T.Bool ++ ",\n") ++
                   ppDealSize0 (T.Array num dataType) "" ("  output " ++ ppDeclType (ppName readRs ++ "$_return") (T.Array num dataType) ++ ",\n")) readLs) ++
   ("  input " ++ ppDeclType (ppName write ++ "$_enable") T.Bool ++ ",\n") ++
  ppDealSize0 writeType "" (("  input " ++ ppDeclType (ppName write ++ "$_argument") writeType ++ ",\n")) ++
  "  input logic CLK,\n" ++
  "  input logic RESET\n" ++
  ");\n" ++
  ppDealSize0 dataType "" ("  " ++ ppDeclType (ppName name ++ "$_data") dataType ++ "[0:" ++ show (idxNum - 1) ++ "] /* verilator public */;\n") ++
  (case reads of
     T.RtlSync isAddr readLs ->
       concatMap (\(T.Build_RtlSyncRead (T.Build_SyncRead readRq readRs readReg) bypRqRs bypWrRd) ->
                    if isAddr
                    then ppDealSize0 (T.Bit (T._Nat__log2_up idxNum)) "" ("  " ++ ppDeclType (ppName readReg) (T.Bit (T._Nat__log2_up idxNum)) ++ ";\n")
                    else ppDealSize0 (T.Array num dataType) "" ("  " ++ ppDeclType (ppName readReg) (T.Array num dataType)) ++
                         ppDealSize0 (T.Array num dataType) "" ("  " ++ ppDeclType (ppName (readReg ++ "$_temp")) (T.Array num dataType))
                 ) readLs
     _ -> "") ++
  "\n" ++
  (case init of
     T.RFFile isAscii isArg file _ ->
       "  initial begin\n" ++
       (if isArg
        then "    string _fileName;\n" ++
             "    $value$plusargs(\"" ++ file ++ "=%s\", _fileName);\n"
        else "") ++
       "    $readmem" ++ (if isAscii then "h" else "b") ++ "(" ++ (if isArg then "_fileName" else "\"" ++ file ++ "\"") ++ ", " ++ ppName name ++ "$_data);\n" ++
       "  end\n\n"
     _ -> "") ++
  let writeByps readAddr i = 
        concatMap (\j -> "(" ++ 
                         "(" ++ ppName write ++ "$_enable && (" ++
                         "(" ++ ppDealSize0 (T.Bit (T._Nat__log2_up idxNum)) "0" (ppName write ++ "$_argument.addr + " ++ show j) ++ ") == " ++
                         "(" ++ ppDealSize0 (T.Bit (T._Nat__log2_up idxNum)) "0" (readAddr ++ " + " ++ show i) ++ "))" ++
                         (if isWrMask
                          then " && " ++ ppName write ++ "$_argument.mask[" ++ show j ++ "]"
                          else "") ++
                         ") ? " ++
                         ppDealSize0 dataType "0" (ppName write ++ "$_argument.data[" ++ show j ++ "]") ++ " : 0) | ")
        [0 .. (num-1)] in
    let readResponse readResp readAddr isByp =
          ppDealSize0 (T.Array num dataType) "" ("  assign " ++ ppName readResp ++ " = " ++ "{" ++
                                                intercalate ", " (map (\i ->
                                                                          ppDealSize0 (T.Bit (T._Nat__log2_up idxNum)) "0" (readAddr ++ " + " ++ show i ++ " < " ++ show idxNum) ++ " ? " ++
                                                                          (if isByp then writeByps readAddr i else "") ++ ppDealSize0 dataType "0" (ppName name ++ "$_data[" ++ (ppDealSize0 (T.Bit (T._Nat__log2_up idxNum)) "0" (readAddr ++ " + " ++ show i)) ++ "]") ++ ": " ++ show (T.size dataType) ++ "'b0")
                                                                  (reverse [0 .. (num-1)])) ++ "};\n") in
      (case reads of
         T.RtlAsync readLs -> concatMap (\(read, bypass) ->
                                         readResponse (read ++ "$_return") (ppName (read ++ "$_argument")) bypass) readLs
         T.RtlSync isAddr readLs ->
           concatMap (\(T.Build_RtlSyncRead (T.Build_SyncRead readRq readRs readReg) bypRqRs bypWrRd) ->
                        if isAddr
                        then readResponse (readRs ++ "$_return") (if bypRqRs then "(" ++ (ppName (readRq ++ "$_enable") ++ "? " ++ ppName (readRq ++ "$_argument") ++ ": " ++ ppName readReg) ++ ")" else ppName readReg) bypWrRd
                        else readResponse (readReg ++ "$_temp") readRq bypWrRd ++
                             ppDealSize0 (T.Array num dataType) "" ("  assign " ++ ppName readRs ++ " = " ++ if bypRqRs then "(" ++ ppName (readRq ++ "$_enable") ++ "? " ++ ppName (readReg ++ "$_temp") ++ ": " ++ ppName readReg ++ ")"  else ppName readReg)
                     ) readLs) ++
  "  always@(posedge CLK) begin\n" ++
  "    if(RESET) begin\n" ++
  (case init of
     T.RFNonFile (Just initVal) ->
       "      for(int _i = 0; _i < " ++ show idxNum ++ "; _i=_i+1) begin\n" ++
       ppDealSize0 dataType "" ("        " ++ ppName name ++ "$_data[_i] = " ++ ppConst initVal ++ ";\n") ++
       "      end\n"
     _ -> "") ++
  "    end else begin\n" ++
  "      if(" ++ ppName write ++ "$_enable) begin\n" ++
  concat (map (\i ->
                 (if isWrMask then "        if(" ++ ppName write ++ "$_argument.mask[" ++ show i ++ "])\n" else "") ++
                ppDealSize0 dataType "" ("          " ++ ppName name ++ "$_data[" ++ ppDealSize0 (T.Bit (T._Nat__log2_up idxNum)) "0" (ppName write ++ "$_argument.addr + " ++ show i) ++ "] <= " ++
                                         ppDealSize0 dataType "" (ppName write ++ "$_argument.data[" ++ show i ++ "]") ++ ";\n")) [0 .. (num-1)]) ++
  "      end\n" ++
  (case reads of
     T.RtlAsync readLs -> ""
     T.RtlSync isAddr readLs ->
       concatMap (\(T.Build_RtlSyncRead (T.Build_SyncRead readRq readRs readReg) bypRqRs bypWrRd) ->
                    if isAddr
                    then "      if(" ++ ppName (readRq ++ "$_enable") ++ ") begin\n" ++
                         "        " ++ ppName readReg ++ " <= " ++ ppName (readRq ++ "$_argument") ++ ";\n" ++
                         "      end\n"
                    else "      if(" ++ ppName (readRq ++ "$_enable") ++ ") begin\n" ++
                         "        " ++ ppName readReg ++ " <= " ++ ppName (readReg ++ "$_temp") ++ ";\n" ++
                         "      end\n"
                 ) readLs) ++
  "    end\n" ++
  "  end\n" ++
  "endmodule\n\n"

removeDups :: Eq a => [(a, b)] -> [(a, b)]
removeDups = nubBy (\(a, _) (b, _) -> a == b)

getAllMethodsRegFileList :: [T.RtlRegFileBase] -> [(String, (T.Kind, T.Kind))]
getAllMethodsRegFileList ls = concat (map (\(T.Build_RtlRegFileBase isWrMask num dataArray readLs write idxNum d init) ->
                                              (write, (T.coq_WriteRq idxNum d, T.Bit 0)) :
                                              (map (\x -> (fst x, (T.Bit (T._Nat__log2_up idxNum), d)))
                                               (case readLs of
                                                  T.RtlAsync reads -> map (\(x, _) -> (x, (T.Bit (T._Nat__log2_up idxNum), d))) reads
                                                  T.RtlSync _ reads -> map (\(T.Build_RtlSyncRead (T.Build_SyncRead rq rs _) _ _) -> (rq, (T.Bit (T._Nat__log2_up idxNum), T.Bit 0))) reads ++
                                                                       map (\(T.Build_RtlSyncRead (T.Build_SyncRead rq rs _) _ _) -> (rs, (T.Bit 0, d))) reads
                                               ))) ls)


ppRtlInstance :: T.RtlModule -> String
ppRtlInstance m@(T.Build_RtlModule hiddenWires regFs ins' outs' regInits' regWrites' assigns' sys') =
  "  _design _designInst(.CLK(CLK), .RESET(RESET)" ++
  concatMap (\(nm, ty) -> ppDealSize0 ty "" (", ." ++ ppPrintVar nm ++ "(" ++ ppPrintVar nm ++ ")")) (removeDups (ins' ++ outs')) ++ ");\n"
              
ppBitFormat :: T.BitFormat -> String
ppBitFormat T.Binary = "b"
ppBitFormat T.Decimal = "d"
ppBitFormat T.Hex = "x"

ppFullBitFormat :: T.FullBitFormat -> String
ppFullBitFormat (sz, f) = "%" ++ show sz ++ ppBitFormat f

ppRtlSys :: T.RtlSysT -> State (H.HashMap String (Int, T.Kind)) String
ppRtlSys (T.RtlDispString s) = return $ "        $write(\"" ++ s ++ "\");\n"
ppRtlSys (T.RtlDispBool e f) = do
  s <- ppRtlExpr "sys" e
  return $ "        $write(\"" ++ ppFullBitFormat f ++ "\", " ++ s ++ ");\n"
ppRtlSys (T.RtlDispBit _ e f) = do
  s <- ppRtlExpr "sys" e
  return $ "        $write(\"" ++ ppFullBitFormat f ++ "\", " ++ s ++ ");\n"
ppRtlSys (T.RtlDispStruct n fk fs fv ff) = do
  rest <- mapM (\i -> ppRtlExpr "sys" (T.RtlReadStruct n fk fs fv i)) (T.getFins n)
  return $ "        $write(\"{" ++ Data.List.concat (Data.List.map (\i -> fs i ++ ":=" ++ ppFullBitFormat (ff i) ++ "; ") (T.getFins n)) ++ "}\", " ++ Data.List.concat rest ++ ");\n"
ppRtlSys (T.RtlDispArray n k v f) = do
  rest <- mapM (\i -> ppRtlExpr "sys" (T.RtlReadArray n k v (T.RtlConst k (T.ConstBit (T._Nat__log2_up n) (T.natToWord (T._Nat__log2_up n) i))))) [0 .. (n-1)]
  return $ "        $write(\"[" ++ Data.List.concat (Data.List.map (\i -> show i ++ ":=" ++ ppFullBitFormat f ++ "; ") [0 .. (n-1)]) ++ "]\", " ++ Data.List.concat rest ++ ");\n"
ppRtlSys (T.RtlFinish) = return $ "        $finish();\n"

ppRtlModule :: T.RtlModule -> String
ppRtlModule m@(T.Build_RtlModule hiddenWires regFs ins' outs' regInits' regWrites' assigns' sys') =
  "module _design(\n" ++
  concatMap (\(nm, ty) -> ppDealSize0 ty "" ("  input " ++ ppDeclType (ppPrintVar nm) ty ++ ",\n")) ins ++ "\n" ++
  concatMap (\(nm, ty) -> ppDealSize0 ty "" ("  output " ++ ppDeclType (ppPrintVar nm) ty ++ ",\n")) outs ++ "\n" ++

  "  input CLK,\n" ++
  "  input RESET\n" ++
  ");\n" ++
  concatMap (\(nm, (T.SyntaxKind ty, init)) -> ppDealSize0 ty "" ("  " ++ ppDeclType (ppName nm) ty ++ ";\n")) regInits ++ "\n" ++

  concatMap (\(nm, (ty, expr)) -> ppDealSize0 ty "" ("  " ++ ppDeclType (ppPrintVar nm) ty ++ ";\n")) assigns ++ "\n" ++

  concatMap (\(sexpr, (pos, ty)) -> ppDealSize0 ty "" ("  " ++ ppDeclType ("_trunc$wire$" ++ show pos) ty ++ ";\n")) assignTruncs ++ "\n" ++
  concatMap (\(sexpr, (pos, ty)) -> ppDealSize0 ty "" ("  " ++ ppDeclType ("_trunc$reg$" ++ show pos) ty ++ ";\n")) regTruncs ++ "\n" ++
  concatMap (\(sexpr, (pos, ty)) -> ppDealSize0 ty "" ("  " ++ ppDeclType ("_trunc$sys$" ++ show pos) ty ++ ";\n")) sysTruncs ++ "\n" ++

  concatMap (\(sexpr, (pos, ty)) -> ppDealSize0 ty "" ("  assign " ++ "_trunc$wire$" ++ show pos ++ " = " ++ sexpr ++ ";\n")) assignTruncs ++ "\n" ++
  concatMap (\(sexpr, (pos, ty)) -> ppDealSize0 ty "" ("  assign " ++ "_trunc$reg$" ++ show pos ++ " = " ++ sexpr ++ ";\n")) regTruncs ++ "\n" ++
  concatMap (\(sexpr, (pos, ty)) -> ppDealSize0 ty "" ("  assign " ++ "_trunc$sys$" ++ show pos ++ " = " ++ sexpr ++ ";\n")) sysTruncs ++ "\n" ++
  
  concatMap (\(nm, (ty, sexpr)) -> ppDealSize0 ty "" ("  assign " ++ ppPrintVar nm ++ " = " ++ sexpr ++ ";\n")) assignExprs ++ "\n" ++

  "  always @(posedge CLK) begin\n" ++
  "    if(RESET) begin\n" ++
  concatMap (\(nm, (T.SyntaxKind ty, init)) -> case init of
                                                 Just (T.SyntaxConst _ v) -> ppDealSize0 ty "" ("      " ++ ppName nm ++ " <= " ++ ppConst v ++ ";\n")
                                                 _ -> "") regInits ++
  "    end\n" ++
  "    else begin\n" ++
  concatMap (\(nm, (ty, sexpr)) -> ppDealSize0 ty "" ("      " ++ ppName nm ++ " <= " ++ sexpr ++ ";\n")) regExprs ++
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


-- ppRfInstance :: RegFileBase -> string
-- ppRfInstance rf@(RegFile dataArray reads write idxNum dataT init) =
--   "  RegFile " ++ dataArray ++ "#(.idxNum(" ++ idxNum ++ "), .dataSz(" ++ size dataT ++ ")) (" ++
  
  
-- ppRfInstance rf@(SyncRegFile isAddr dataArray reads write idxNum dataT init) =


ppTopModule :: T.RtlModule -> String
ppTopModule m@(T.Build_RtlModule hiddenWires regFs ins' outs' regInits' regWrites' assigns' sys') =
  concatMap ppRfModule regFs ++
  ppRtlModule m ++
  "module top(\n" ++
  concatMap (\(nm, ty) -> ppDealSize0 ty "" ("  input " ++ ppDeclType (ppPrintVar nm) ty ++ ",\n")) insFiltered ++ "\n" ++
  concatMap (\(nm, ty) -> ppDealSize0 ty "" ("  output " ++ ppDeclType (ppPrintVar nm) ty ++ ",\n")) outsFiltered ++ "\n" ++
  "  input CLK,\n" ++
  "  input RESET\n" ++
  ");\n" ++
  concatMap (\(nm, ty) -> ppDealSize0 ty "" ("  " ++ ppDeclType (ppPrintVar nm) ty ++ ";\n")) ins ++ "\n" ++
  concatMap (\(nm, ty) -> ppDealSize0 ty "" ("  " ++ ppDeclType (ppPrintVar nm) ty ++ ";\n")) outs ++ "\n" ++
  concatMap ppRfInstance regFs ++
  ppRtlInstance m ++
  "endmodule\n"
  where
    ins = removeDups ins'
    outs = removeDups outs'
    isHidden (x, _) = not (elem x hiddenWires)
    insFiltered = Data.List.filter isHidden ins
    outsFiltered = Data.List.filter isHidden outs
              
printDiff :: [(String, [String])] -> [(String, [String])] -> IO ()
printDiff (x:xs) (y:ys) =
  do
    if x == y
    then printDiff xs ys
    else putStrLn $ (show x) ++ " " ++ (show y)
printDiff [] [] = return ()
printDiff _ _ = putStrLn "Wrong lengths"

ppConstMem :: T.ConstT -> String
ppConstMem (T.ConstBool b) = if b then "1" else "0"
ppConstMem (T.ConstBit sz w) = if sz == 0 then "0" else ppWord (reverse $ wordToList w)
ppConstMem (T.ConstStruct num fk fs fv) = Data.List.concatMap ppConstMem (Data.List.map fv (T.getFins num))
ppConstMem (T.ConstArray num k fv) = Data.List.concatMap ppConstMem (reverse $ Data.List.map fv (T.getFins num))

ppRfFile :: (((String, [(String, Bool)]), String), ((Int, T.Kind), T.ConstT)) -> String
ppRfFile (((name, reads), write), ((idxType, dataType), T.ConstArray num k fv)) =
  concatMap (\v -> ppConstMem v ++ "\n") (reverse $ Data.List.map fv (T.getFins num)) ++ "\n"

ppRfName :: (((String, [(String, Bool)]), String), ((Int, T.Kind), T.ConstT)) -> String
ppRfName (((name, reads), write), ((idxType, dataType), T.ConstArray num k fv)) = ppName name ++ ".mem"

main =
  -- do
  --   let !t = show rtlMod
  --   putStr t
  do
    putStrLn $ ppTopModule T.rtlMod
    --let (Build_RtlModule hiddenMeths regFs _ _ _ _ _ _) = rtlMod in
    --  mapM_ (\rf -> writeFile (ppRfName rf) (ppRfFile rf)) regFs
