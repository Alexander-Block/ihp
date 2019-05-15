{-# LANGUAGE MultiParamTypeClasses, TypeFamilies, FlexibleContexts, AllowAmbiguousTypes, UndecidableInstances, FlexibleInstances, IncoherentInstances, DataKinds, PolyKinds, TypeApplications, ScopedTypeVariables, TypeInType, ConstraintKinds, TypeOperators, GADTs #-}

module Foundation.ModelSupport where

import Foundation.HaskellSupport
import ClassyPrelude hiding (UTCTime, find)
import qualified ClassyPrelude
import Database.PostgreSQL.Simple (Connection)
import qualified Text.Inflections
import Database.PostgreSQL.Simple.Types (Query (Query))
import Database.PostgreSQL.Simple.FromField hiding (Field, name)
import Database.PostgreSQL.Simple.ToField
import Data.Default
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.String.Conversions (cs)
import Data.Time.Clock (UTCTime)
import Unsafe.Coerce
import Data.UUID
import qualified Database.PostgreSQL.Simple as PG
import qualified Database.PostgreSQL.Simple.Types as PG
import GHC.Records
import GHC.OverloadedLabels
import Data.String.Conversions (cs)
import GHC.TypeLits
import GHC.Types
import Data.Proxy
import Foundation.DatabaseSupport.Point
import GHC.Generics
import Data.Data
import qualified Control.Newtype.Generics as Newtype

data ModelContext = ModelContext {-# UNPACK #-} !Connection

type family GetModelById id :: Type
type family GetTableName model :: Symbol

class CanCreate a where
    type Created a :: Type
    create :: (?modelContext :: ModelContext) => a -> IO (Created a)
    createMany :: (?modelContext :: ModelContext) => [a] -> IO [Created a]

class CanUpdate a where
    updateRecord :: (?modelContext :: ModelContext) => a -> IO a

{-# INLINE createRecord #-}
createRecord :: (?modelContext :: ModelContext, CanCreate model) => model -> IO (Created model)
createRecord = create

-- TODO: remove
class FindWhere a where
    type FindWhereResult a :: Type
    findWhere :: (?modelContext :: ModelContext) => a -> IO [FindWhereResult a]
    buildCriteria :: a

class FormField field where
    formFieldName :: field -> Text
    formFieldLabel :: field -> Text
    formFieldLabel field =
        let
            name = formFieldName field
            (Right parts) = Text.Inflections.parseSnakeCase [] name
        in Text.Inflections.titleize parts

class FormFieldValue field model where
    formFieldValue :: field -> model -> Text

class InputValue a where
    inputValue :: a -> Text

instance InputValue Text where
    inputValue text = text

instance InputValue Int where
    inputValue = tshow

instance InputValue Bool where
    inputValue True = "on"
    inputValue False = "off"

instance InputValue Data.UUID.UUID where
    inputValue = Data.UUID.toText

instance InputValue () where
    inputValue () = "error: inputValue(()) not supported"

instance InputValue UTCTime where
    inputValue time =
        let fullDateTime = cs (iso8601Show time)
        in fullDateTime

instance InputValue ClassyPrelude.UTCTime where
    inputValue time = inputValue ((unsafeCoerce time) :: UTCTime)

instance InputValue fieldType => InputValue (Maybe fieldType) where
    inputValue (Just value) = inputValue value
    inputValue Nothing = ""

instance Default Text where
    {-# INLINE def #-}
    def = ""

instance Default Bool where
    {-# INLINE def #-}
    def = False

instance Default Point where
    {-# INLINE def #-}
    def = Point 0 0




type FieldName = ByteString

class IsNew model where
    isNew :: model -> Bool

class IsNewId id where
    isNewId :: id -> Bool
instance IsNewId () where isNewId _ = True
instance IsNewId UUID where isNewId _ = False

type family GetModelName model :: Symbol where
    GetModelName (M1 D ('MetaData name _ _ _) f ()) = name
    GetModelName a = GetModelName (Rep a ())

{-# INLINE getModelName #-}
getModelName :: forall model. KnownSymbol (GetModelName model) => Text
getModelName = cs $! symbolVal (Proxy :: Proxy (GetModelName model))

newtype Id' table = Id UUID deriving (Eq, Data)

-- We need to map the model to it's table name to prevent infinite recursion in the model data definition
-- E.g. `type Project = Project' { id :: Id Project }` will not work
-- But `type Project = Project' { id :: Id "projects" }` will
type Id model = Id' (New model)

class HasTableName model where
    getTableName :: model -> Text

instance IsNewId (Id' model) where
    {-# INLINE isNewId #-}
    isNewId _ = False

instance InputValue (Id' model') where
    {-# INLINE inputValue #-}
    inputValue = inputValue . Newtype.unpack


instance FromField (Id' model) where
    {-# INLINE fromField #-}
    fromField value metaData = do
        fieldValue <- fromField value metaData
        return $ ((Id fieldValue))

instance ToField (Id' model) where
    {-# INLINE toField #-}
    toField = toField . Newtype.unpack

instance Show (Id' model) where
    {-# INLINE show #-}
    show = show . Newtype.unpack

instance Newtype.Newtype (Id' model) where
    type O (Id' model) = UUID
    pack = Id
    unpack (Id uuid) = uuid

instance Default (Id' model) where
    {-# INLINE def #-}
    def = Newtype.pack def


{-# INLINE sqlQuery #-}
sqlQuery :: (?modelContext :: ModelContext) => (PG.ToRow q, PG.FromRow r) => Query -> q -> IO [r]
sqlQuery = let (ModelContext conn) = ?modelContext in PG.query conn

{-# INLINE deleteRecord #-}
deleteRecord :: (?modelContext::ModelContext, Show model) => (HasTableName model, HasField "id" model id, model ~ GetModelById id, ToField id) => model -> IO ()
deleteRecord model = do
    let (ModelContext conn) = ?modelContext
    let id = getField @"id" model
    let tableName = getTableName model
    putStrLn ("deleteRecord " <> tshow model)
    PG.execute conn (PG.Query . cs $! "DELETE FROM " <> tableName <> " WHERE id = ?") (PG.Only id)
    return ()

findOrNothing :: forall id model model'. (?modelContext :: ModelContext) => (ToField (Id model'), PG.FromRow (GetModelById (Id model')), KnownSymbol (GetTableName (GetModelById (Id model')))) => Id model' -> IO (Maybe (GetModelById (Id model')))
findOrNothing id = do
    let tableName = symbolVal @(GetTableName (GetModelById (Id model'))) Proxy
    results <- sqlQuery (PG.Query $! "SELECT * FROM " <> cs tableName <> " WHERE id = ? LIMIT 1") [id]
    return $ headMay results

class ColumnNames model where
    type ColumnNamesRecord model :: GHC.Types.Type
    columnNames :: Proxy model -> ColumnNamesRecord model

type family ModelFieldType model :: GHC.Types.Type
type family ModelFieldValue model (field :: GHC.Types.Symbol) :: GHC.Types.Type

type family Include (name :: GHC.Types.Symbol) model

type family New model

type family Include' (name :: [GHC.Types.Symbol]) model where
    Include' '[] model = model
    Include' (x:xs) model = Include' xs (Include x model)

-- data family Table model f
-- data instance Table User f = UserTable
--     { id :: f ('UUIDField { defaultValue = Nothing, references = Nothing, allowNull = False, isPrimaryKey = False, onDelete = NoAction, unique = False })
--     }
--