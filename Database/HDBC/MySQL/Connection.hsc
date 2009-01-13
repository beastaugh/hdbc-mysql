-- -*- mode: haskell; -*-
{-# OPTIONS -fglasgow-exts #-}

module Database.HDBC.MySQL.Connection
    (connectMySQL, Connection())
where

import Control.Exception
import Control.Monad
import Foreign
import Foreign.C
import Data.Time
import Data.Time.Clock.POSIX

import qualified Database.HDBC.Types as Types
import Database.HDBC.ColTypes as ColTypes

#include <mysql.h>

data Connection = Connection
    { disconnect :: IO ()
    , commit :: IO ()
    , rollback :: IO ()
    , run :: String -> [Types.SqlValue] -> IO Integer
    , prepare :: String -> IO Types.Statement
    , clone :: IO Connection
    , hdbcDriverName :: String
    , hdbcClientVer :: String
    , proxiedClientName :: String
    , proxiedClientVer :: String
    , dbServerVer :: String
    , dbTransactionSupport :: Bool
    , getTables :: IO [String]
    , describeTable :: String -> IO [(String, ColTypes.SqlColDesc)]
    }

instance Types.IConnection Connection where
  disconnect           = disconnect
  commit               = commit
  rollback             = rollback
  run                  = run
  prepare              = prepare
  clone                = clone
  hdbcDriverName       = hdbcDriverName
  hdbcClientVer        = hdbcClientVer
  proxiedClientName    = proxiedClientName
  proxiedClientVer     = proxiedClientVer
  dbServerVer          = dbServerVer
  dbTransactionSupport = dbTransactionSupport
  getTables            = getTables
  describeTable        = describeTable

-- The "real" connection to the MySQL server.  Wraps mysql.h's MYSQL
-- struct.  We don't ever need to look inside it.
data MYSQL

-- Connects to the MySQL database.
connectMySQL :: String -> String -> String -> String -> Int -> String -> IO Connection
connectMySQL host user passwd db port unixSocket = do
  mysql_ <- mysql_init nullPtr
  when (mysql_ == nullPtr) (error "mysql_init failed")
  withCString host $ \host_ ->
      withCString user $ \user_ ->
          withCString passwd $ \passwd_ ->
              withCString db $ \db_ ->
                  withCString unixSocket $ \unixSocket_ ->
                      do rv <- mysql_real_connect mysql_ host_ user_ passwd_ db_ (fromIntegral port) unixSocket_
                         when (rv == nullPtr) (connectionError mysql_)
                         wrap mysql_
    where
      -- Returns the HDBC wrapper for the native MySQL connection
      -- object.
      wrap :: Ptr MYSQL -> IO Connection
      wrap mysql_ = do
        clientver <- peekCString =<< mysql_get_client_info
        serverver <- peekCString =<< mysql_get_server_info mysql_
        protover <- mysql_get_proto_info mysql_

        -- HDBC assumes that there is no such thing as auto-commit.
        -- So we'll turn it off here and start our first transaction.
        mysql_autocommit mysql_ 0
        doStartTransaction mysql_

        return $ Connection
                   { disconnect           = mysql_close mysql_
                   , commit               = doCommit mysql_
                   , rollback             = doRollback mysql_
                   , run                  = doRun mysql_
                   , prepare              = newStatement mysql_
                   , clone                = connectMySQL host user passwd db port unixSocket
                   , hdbcDriverName       = "mysql"
                   , hdbcClientVer        = clientver
                   , proxiedClientName    = "mysql"
                   , proxiedClientVer     = show protover
                   , dbServerVer          = serverver
                   , dbTransactionSupport = True
                   , getTables            = doGetTables mysql_
                   , describeTable        = error "describeTable"
                   }

-- A MySQL statement: wraps mysql.h's MYSQL_STMT struct.
data MYSQL_STMT

-- A MySQL result: wraps mysql.h's MYSQL_RES struct.
data MYSQL_RES

-- A MySQL field: wraps mysql.h's MYSQL_FIELD struct.  We do actually
-- have to spelunk this structure, so it's a Storable instance.
data MYSQL_FIELD = MYSQL_FIELD
    { fieldName      :: String
    , fieldLength    :: CULong
    , fieldMaxLength :: CULong
    , fieldType      :: CInt
    , fieldDecimals  :: CUInt
    }

instance Storable MYSQL_FIELD where
    sizeOf _     = #const sizeof(MYSQL_FIELD)
    alignment _  = alignment (undefined :: CInt)

    peek p = do
      fname   <- peekCString =<< (#peek MYSQL_FIELD, name) p
      flength <- (#peek MYSQL_FIELD, length) p
      fmaxlen <- (#peek MYSQL_FIELD, max_length) p
      ftype   <- (#peek MYSQL_FIELD, type) p
      fdec    <- (#peek MYSQL_FIELD, decimals) p
      return $ MYSQL_FIELD
                 { fieldName      = fname
                 , fieldLength    = flength
                 , fieldMaxLength = fmaxlen
                 , fieldType      = ftype
                 , fieldDecimals  = fdec
                 }

    poke _ _ = error "MYSQL_FIELD: poke"

-- A MySQL binding to a query parameter or result.  This wraps
-- mysql.h's MYSQL_BIND struct, and it's also Storable -- in this
-- case, so that we can create them.
data MYSQL_BIND = MYSQL_BIND
    { bindLength       :: Ptr CULong
    , bindIsNull       :: Ptr CChar
    , bindBuffer       :: Ptr ()
    , bindError        :: Ptr CChar
    , bindBufferType   :: CInt
    , bindBufferLength :: CULong
    }

instance Storable MYSQL_BIND where
    sizeOf _      = #const sizeof(MYSQL_BIND)
    alignment _   = alignment (undefined :: CInt)

    peek _ = error "MYSQL_BIND: peek"

    poke p (MYSQL_BIND len_ isNull_ buf_ err_ buftyp buflen) = do
        memset (castPtr p) 0 #{const sizeof(MYSQL_BIND)}
        (#poke MYSQL_BIND, length)        p len_
        (#poke MYSQL_BIND, is_null)       p isNull_
        (#poke MYSQL_BIND, buffer)        p buf_
        (#poke MYSQL_BIND, error)         p err_
        (#poke MYSQL_BIND, buffer_type)   p buftyp
        (#poke MYSQL_BIND, buffer_length) p buflen

data MYSQL_TIME = MYSQL_TIME
    { timeYear       :: CInt
    , timeMonth      :: CInt
    , timeDay        :: CInt
    , timeHour       :: CInt
    , timeMinute     :: CInt
    , timeSecond     :: CInt
    }

instance Storable MYSQL_TIME where
    sizeOf _      = #const sizeof(MYSQL_TIME)
    alignment _   = alignment (undefined :: CInt)

    peek p = do
      year    <- (#peek MYSQL_TIME, year) p
      month   <- (#peek MYSQL_TIME, month) p
      day     <- (#peek MYSQL_TIME, day) p
      hour    <- (#peek MYSQL_TIME, hour) p
      minute  <- (#peek MYSQL_TIME, minute) p
      second  <- (#peek MYSQL_TIME, second) p
      return (MYSQL_TIME year month day hour minute second)

    poke p t = do
      memset (castPtr p) 0 #{const sizeof(MYSQL_TIME)}
      (#poke MYSQL_TIME, year)   p (timeYear t)
      (#poke MYSQL_TIME, month)  p (timeMonth t)
      (#poke MYSQL_TIME, day)    p (timeDay t)
      (#poke MYSQL_TIME, hour)   p (timeHour t)
      (#poke MYSQL_TIME, minute) p (timeMinute t)
      (#poke MYSQL_TIME, second) p (timeSecond t)

-- Prepares a new Statement for execution.
newStatement :: Ptr MYSQL -> String -> IO Types.Statement
newStatement mysql_ query = do
  -- XXX it would probably make sense to revisit the flow-of-control
  -- here: if we blow up while preparing the statement, we'll bail
  -- without closing it.
  stmt_ <- mysql_stmt_init mysql_
  when (stmt_ == nullPtr) (connectionError mysql_)

  withCString query $ \query_ -> do
      rv <- mysql_stmt_prepare stmt_ query_ (fromIntegral $ length query)
      when (rv /= 0) (statementError stmt_)

  -- Collect the result fields of the statement; this will simply be
  -- the empty list if we're doing something that doesn't generate
  -- results.
  fields <- fieldsOf stmt_

  -- Create MYSQL_BIND structures for each field and point the the
  -- statement at those buffers.  Again, if there are no fields,
  -- this'll be a no-op.
  results <- mapM resultOfField fields
  withArray results $ \bind_ -> do
      rv' <- mysql_stmt_bind_result stmt_ bind_
      when (rv' /= 0) (statementError stmt_)

  return $ Types.Statement
             { Types.execute        = execute stmt_
             , Types.executeMany    = mapM_ $ execute stmt_
             , Types.finish         = mysql_stmt_close stmt_ >> return ()
             , Types.fetchRow       = fetchRow stmt_ results
             , Types.originalQuery  = query
             , Types.getColumnNames = return $ map fieldName fields
             , Types.describeResult = error "describeResult"
             }

-- Returns the list of fields from a prepared statement.
fieldsOf :: Ptr MYSQL_STMT -> IO [MYSQL_FIELD]
fieldsOf stmt_ = bracket acquire release fieldsOf'
    where acquire                          = mysql_stmt_result_metadata stmt_
          release res_ | res_ == nullPtr   = return ()
                       | otherwise         = mysql_free_result res_
          fieldsOf' res_ | res_ == nullPtr = return []
                         | otherwise       = fieldsOfResult res_

-- Builds the list of fields from the result set metadata: this is
-- just a helper function for fieldOf, above.
fieldsOfResult :: Ptr MYSQL_RES -> IO [MYSQL_FIELD]
fieldsOfResult res_ = do
  field_ <- mysql_fetch_field res_
  if (field_ == nullPtr)
    then return []
    else liftM2 (:) (peek field_) (fieldsOfResult res_)

-- Executes a statement with the specified binding parameters.
execute :: Ptr MYSQL_STMT -> [Types.SqlValue] -> IO Integer
execute stmt_ params = do
  bindParams stmt_ params
  rv <- mysql_stmt_execute stmt_
  when (rv /= 0) (statementError stmt_)
  nrows <- mysql_stmt_affected_rows stmt_
  return $ fromIntegral nrows

-- Binds placeholder parameters to values.
bindParams :: Ptr MYSQL_STMT -> [Types.SqlValue] -> IO ()
bindParams stmt_ params = do
  param_count <- mysql_stmt_param_count stmt_
  let nparams = fromIntegral param_count

  -- XXX i'm not sure if it makes more sense to keep this paranoia, or
  -- to simply remove it.  The code that immediately follows pads
  -- extra bind parameters with nulls.
  when (nparams /= length params)
           (error "the number of parameter placeholders in the prepared SQL is different than the number of parameters provided")

  let params' = take nparams $ params ++ repeat Types.SqlNull
  binds <- mapM bindOfSqlValue params'
  withArray binds $ \bind_ -> do
      rv <- mysql_stmt_bind_param stmt_ bind_
      when (rv /= 0) (statementError stmt_)

-- Given a SqlValue, return a MYSQL_BIND structure that we can use to
-- pass its value.
bindOfSqlValue :: Types.SqlValue -> IO MYSQL_BIND

bindOfSqlValue Types.SqlNull =
    with (1 :: CChar) $ \isNull_ ->
        return $ MYSQL_BIND
                   { bindLength       = nullPtr
                   , bindIsNull       = isNull_
                   , bindBuffer       = nullPtr
                   , bindError        = nullPtr
                   , bindBufferType   = #{const MYSQL_TYPE_NULL}
                   , bindBufferLength = 0
                   }

bindOfSqlValue (Types.SqlString s) =
    bindOfSqlValue' (length s) (withCString s) #{const MYSQL_TYPE_VAR_STRING}

bindOfSqlValue (Types.SqlByteString _) =
    error "bindOfSqlValue :: SqlByteString"

bindOfSqlValue (Types.SqlInteger n) =
    bindOfSqlValue' (8::Int) (with (fromIntegral n :: CLLong)) #{const MYSQL_TYPE_LONGLONG}

bindOfSqlValue (Types.SqlBool b) =
    bindOfSqlValue' (1::Int) (with (if b then 1 else 0 :: CChar)) #{const MYSQL_TYPE_TINY}

bindOfSqlValue (Types.SqlChar c) =
    bindOfSqlValue' (1::Int) (with c) #{const MYSQL_TYPE_TINY}

bindOfSqlValue (Types.SqlDouble d) =
    bindOfSqlValue' (8::Int) (with (realToFrac d :: CDouble)) #{const MYSQL_TYPE_DOUBLE}

bindOfSqlValue (Types.SqlInt32 n) =
    bindOfSqlValue' (4::Int) (with n) #{const MYSQL_TYPE_LONG}

bindOfSqlValue (Types.SqlInt64 n) =
    bindOfSqlValue' (8::Int) (with n) #{const MYSQL_TYPE_LONGLONG}

bindOfSqlValue (Types.SqlRational n) =
    bindOfSqlValue' (8::Int) (with (realToFrac n :: CDouble)) #{const MYSQL_TYPE_DOUBLE}

bindOfSqlValue (Types.SqlWord32 n) =
    bindOfSqlValue' (4::Int) (with n) #{const MYSQL_TYPE_LONG}

bindOfSqlValue (Types.SqlWord64 n) =
    bindOfSqlValue' (8::Int) (with n) #{const MYSQL_TYPE_LONGLONG}

bindOfSqlValue (Types.SqlEpochTime epoch) =
    let t = utcToMysqlTime $ posixSecondsToUTCTime (fromIntegral epoch) in
    bindOfSqlValue' (#{const sizeof(MYSQL_TIME)}::Int) (with t) #{const MYSQL_TYPE_DATETIME}
        where utcToMysqlTime :: UTCTime -> MYSQL_TIME
              utcToMysqlTime (UTCTime day difftime) =
                  let (y, m, d) = toGregorian day
                      t  = floor $ (realToFrac difftime :: Double)
                      h  = t `div` 3600
                      mn = t `div` 60 `mod` 60
                      s  = t `mod` 60
                  in MYSQL_TIME (fromIntegral y) (fromIntegral m) (fromIntegral d) h mn s

bindOfSqlValue (Types.SqlTimeDiff _) =
    error "bindOfSqlValue :: SqlTimeDiff"

-- A nasty helper function that cuts down on the boilerplate a bit.
bindOfSqlValue' :: (Integral a, Storable b) =>
                   a ->
                       ((Ptr b -> IO MYSQL_BIND) -> IO MYSQL_BIND) ->
                           CInt ->
                               IO MYSQL_BIND

bindOfSqlValue' len buf btype =
    let buflen = fromIntegral len in
    with (0 :: CChar) $ \isNull_ -> 
        with buflen $ \len_ ->
            buf $ \buf_ ->
                return $ MYSQL_BIND
                           { bindLength       = len_
                           , bindIsNull       = isNull_
                           , bindBuffer       = castPtr buf_
                           , bindError        = nullPtr
                           , bindBufferType   = btype
                           , bindBufferLength = buflen
                           }

-- Returns an appropriate binding structure for a field.
resultOfField :: MYSQL_FIELD -> IO MYSQL_BIND
resultOfField field =
    let ftype = fieldType field
        btype = boundType ftype (fieldDecimals field)
        size  = boundSize btype (fieldLength field) in
    with size $ \size_ ->
        with (0 :: CChar) $ \isNull_ ->
            with (0 :: CChar) $ \error_ ->
                allocaBytes (fromIntegral size) $ \buffer_ ->
                    return $ MYSQL_BIND { bindLength       = size_
                                        , bindIsNull       = isNull_
                                        , bindBuffer       = buffer_
                                        , bindError        = error_
                                        , bindBufferType   = btype
                                        , bindBufferLength = size
                                        }

-- Returns the appropriate result type for a particular host type.
boundType :: CInt -> CUInt -> CInt
boundType #{const MYSQL_TYPE_STRING}     _ = #{const MYSQL_TYPE_VAR_STRING}
boundType #{const MYSQL_TYPE_TINY}       _ = #{const MYSQL_TYPE_LONG}
boundType #{const MYSQL_TYPE_SHORT}      _ = #{const MYSQL_TYPE_LONG}
boundType #{const MYSQL_TYPE_INT24}      _ = #{const MYSQL_TYPE_LONG}
boundType #{const MYSQL_TYPE_YEAR}       _ = #{const MYSQL_TYPE_LONG}
boundType #{const MYSQL_TYPE_ENUM}       _ = #{const MYSQL_TYPE_LONG}
boundType #{const MYSQL_TYPE_DECIMAL}    0 = #{const MYSQL_TYPE_LONGLONG}
boundType #{const MYSQL_TYPE_DECIMAL}    _ = #{const MYSQL_TYPE_DOUBLE}
boundType #{const MYSQL_TYPE_NEWDECIMAL} 0 = #{const MYSQL_TYPE_LONGLONG}
boundType #{const MYSQL_TYPE_NEWDECIMAL} _ = #{const MYSQL_TYPE_DOUBLE}
boundType #{const MYSQL_TYPE_FLOAT}      _ = #{const MYSQL_TYPE_DOUBLE}
boundType #{const MYSQL_TYPE_DATE}       _ = #{const MYSQL_TYPE_DATETIME}
boundType #{const MYSQL_TYPE_TIMESTAMP}  _ = #{const MYSQL_TYPE_DATETIME}
boundType #{const MYSQL_TYPE_NEWDATE}    _ = #{const MYSQL_TYPE_DATETIME}
boundType t                              _ = t

-- Returns the amount of storage required for a particular result
-- type.
boundSize :: CInt -> CULong -> CULong
boundSize #{const MYSQL_TYPE_LONG}   _ = 4
boundSize #{const MYSQL_TYPE_DOUBLE} _ = 8
boundSize _                          n = n

-- Fetches a row from an executed statement and converts the cell
-- values into a list of SqlValue types.
fetchRow :: Ptr MYSQL_STMT -> [MYSQL_BIND] -> IO (Maybe [Types.SqlValue])
fetchRow stmt_ results = do
  rv <- mysql_stmt_fetch stmt_
  case rv of
    0                             -> row
    #{const MYSQL_DATA_TRUNCATED} -> row
    #{const MYSQL_NO_DATA}        -> return Nothing
    _                             -> statementError stmt_
    where row = mapM cellValue results >>= \cells -> return $ Just cells

-- Produces a single SqlValue cell value given the binding, handling
-- nulls appropriately.
cellValue :: MYSQL_BIND -> IO Types.SqlValue
cellValue bind = do
  isNull <- peek $ bindIsNull bind
  if isNull == 0
    then nonNullCellValue (bindBufferType bind) (bindBuffer bind)
    else return Types.SqlNull

-- Produces a single SqlValue from the binding's type and buffer
-- pointer.
nonNullCellValue :: CInt -> Ptr () -> IO Types.SqlValue

nonNullCellValue #{const MYSQL_TYPE_LONG} p = do
  n :: CLong <- peek $ castPtr p
  return $ Types.SqlInteger (fromIntegral n)

nonNullCellValue #{const MYSQL_TYPE_LONGLONG} p = do
  n :: CLLong <- peek $ castPtr p
  return $ Types.SqlInteger (fromIntegral n)

nonNullCellValue #{const MYSQL_TYPE_DOUBLE} p = do
  n :: CDouble <- peek $ castPtr p
  return $ Types.SqlDouble (realToFrac n)

nonNullCellValue #{const MYSQL_TYPE_VAR_STRING} p =
    peekCString (castPtr p) >>= return . Types.SqlString

nonNullCellValue #{const MYSQL_TYPE_DATETIME} p = do
  t :: MYSQL_TIME <- peek $ castPtr p
  let epoch = (floor . toRational . utcTimeToPOSIXSeconds . mysqlTimeToUTC) t
  return $ Types.SqlEpochTime epoch
      where mysqlTimeToUTC :: MYSQL_TIME -> UTCTime
            mysqlTimeToUTC (MYSQL_TIME y m d h mn s) =
                let day = fromGregorian (fromIntegral y) (fromIntegral m) (fromIntegral d)
                    time = s + mn * 60 + h * 3600
                in UTCTime day (secondsToDiffTime $ fromIntegral time)



nonNullCellValue t _ = return $ Types.SqlString ("unknown type " ++ show t)

doRun :: Ptr MYSQL -> String -> [Types.SqlValue] -> IO Integer
doRun mysql_ query params = do
  stmt <- newStatement mysql_ query
  Types.execute stmt params

doQuery :: Ptr MYSQL -> String -> IO ()
doQuery mysql_ stmt =
    withCString stmt $ \stmt_ -> do
      rv <- mysql_query mysql_ stmt_
      when (rv /= 0) (connectionError mysql_)

doCommit :: Ptr MYSQL -> IO ()
doCommit = flip doQuery $ "COMMIT"
  
doRollback :: Ptr MYSQL -> IO ()
doRollback = flip doQuery $ "ROLLBACK"

doStartTransaction :: Ptr MYSQL -> IO ()
doStartTransaction = flip doQuery $ "START TRANSACTION"

doGetTables :: Ptr MYSQL -> IO [String]
doGetTables mysql_ = do
  stmt <- newStatement mysql_ "SHOW TABLES"
  Types.execute stmt []
  rows <- unfoldRows stmt
  return $ map (fromSql . head) rows
      where unfoldRows stmt = do
              row <- Types.fetchRow stmt
              case row of
                Nothing     -> return []
                Just (vals) -> do rows <- unfoldRows stmt
                                  return (vals : rows)

            fromSql :: Types.SqlValue -> String
            fromSql (Types.SqlString s) = s
            fromSql _                   = error "SHOW TABLES returned a table whose name wasn't a string"

-- Returns the last statement-level error.
statementError :: Ptr MYSQL_STMT -> IO a
statementError stmt_ = do
  errno <- mysql_stmt_errno stmt_
  msg <- peekCString =<< mysql_stmt_error stmt_ 
  --throwDyn $ Types.SqlError "" errno msg
  error (msg ++ " (" ++ show errno ++ ")")

-- Returns the last connection-level error.
connectionError :: Ptr MYSQL -> IO a
connectionError mysql_ = do
  errno <- mysql_errno mysql_
  msg <- peekCString =<< mysql_error mysql_
  --throwDyn $ Types.SqlError "" errno msg
  error (msg ++ " (" ++ show errno ++ ")")

{- ---------------------------------------------------------------------- -}

-- Here are all the FFI imports.

foreign import ccall unsafe mysql_get_client_info
    :: IO CString

foreign import ccall unsafe mysql_get_server_info
    :: Ptr MYSQL -> IO CString

foreign import ccall unsafe mysql_get_proto_info
    :: Ptr MYSQL -> IO CUInt

foreign import ccall unsafe mysql_init
 :: Ptr MYSQL
 -> IO (Ptr MYSQL)

foreign import ccall unsafe mysql_real_connect
 :: Ptr MYSQL -- the context
 -> CString   -- hostname
 -> CString   -- username
 -> CString   -- password
 -> CString   -- database
 -> CInt      -- port
 -> CString   -- unix socket
 -> IO (Ptr MYSQL)

foreign import ccall unsafe mysql_close
    :: Ptr MYSQL -> IO ()

foreign import ccall unsafe mysql_stmt_init
    :: Ptr MYSQL -> IO (Ptr MYSQL_STMT)

foreign import ccall unsafe mysql_stmt_prepare
    :: Ptr MYSQL_STMT -> CString -> CInt -> IO CInt

foreign import ccall unsafe mysql_stmt_result_metadata
    :: Ptr MYSQL_STMT -> IO (Ptr MYSQL_RES)

foreign import ccall unsafe mysql_stmt_bind_param
    :: Ptr MYSQL_STMT -> Ptr MYSQL_BIND -> IO CChar

foreign import ccall unsafe mysql_stmt_bind_result
    :: Ptr MYSQL_STMT -> Ptr MYSQL_BIND -> IO CChar

foreign import ccall unsafe mysql_stmt_param_count
    :: Ptr MYSQL_STMT -> IO CULong

foreign import ccall unsafe mysql_free_result
    :: Ptr MYSQL_RES -> IO ()

foreign import ccall unsafe mysql_stmt_execute
    :: Ptr MYSQL_STMT -> IO CInt

foreign import ccall unsafe mysql_stmt_affected_rows
    :: Ptr MYSQL_STMT -> IO CULLong

foreign import ccall unsafe mysql_fetch_field
    :: Ptr MYSQL_RES -> IO (Ptr MYSQL_FIELD)

foreign import ccall unsafe mysql_stmt_fetch
    :: Ptr MYSQL_STMT -> IO CInt

foreign import ccall unsafe mysql_stmt_close
    :: Ptr MYSQL_STMT -> IO CChar

foreign import ccall unsafe mysql_stmt_errno
    :: Ptr MYSQL_STMT -> IO CInt

foreign import ccall unsafe mysql_stmt_error
    :: Ptr MYSQL_STMT -> IO CString

foreign import ccall unsafe mysql_errno
    :: Ptr MYSQL -> IO CInt

foreign import ccall unsafe mysql_error
    :: Ptr MYSQL -> IO CString

foreign import ccall unsafe mysql_autocommit
    :: Ptr MYSQL -> CChar -> IO CChar

foreign import ccall unsafe mysql_query
    :: Ptr MYSQL -> CString -> IO CInt

foreign import ccall unsafe memset
    :: Ptr () -> CInt -> CSize -> IO ()
