{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Reflex.Dom.Colonnade
  (
  -- * Types
    Cell(..)
  -- * Table Encoders
  , basic
  , static
  , capped
  , cappedTraversing
  , dynamic
  , dynamicCapped
    -- * Cell Functions
  , cell
  , charCell
  , stringCell
  , textCell
  , lazyTextCell
  , builderCell
  ) where

import Data.String (IsString(..))
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.Builder as LT
import qualified Data.Map.Strict as M
import Data.Foldable (Foldable(..),for_)
import Data.Traversable (for)
import Data.Semigroup (Semigroup(..))
import Control.Applicative (liftA2)
import Reflex.Dom
import Colonnade (Colonnade,Headed,Fascia,Cornice)
import qualified Colonnade.Encode as E

data Cell t m b = Cell
  { cellAttrs    :: !(Dynamic t (M.Map T.Text T.Text))
  , cellContents :: !(m b)
  } deriving (Functor)

elFromCell :: (DomBuilder t m, PostBuild t m) => T.Text -> Cell t m b -> m b
elFromCell e (Cell attr m) = elDynAttr e attr m

-- | Convenience function for creating a 'Cell' representing
--   a @td@ or @th@ with no attributes.
cell :: Reflex t => m b -> Cell t m b
cell = Cell (pure M.empty)

charCell :: DomBuilder t m => Char -> Cell t m ()
charCell = textCell . T.singleton

stringCell :: DomBuilder t m => String -> Cell t m ()
stringCell = cell . text . T.pack

textCell :: DomBuilder t m => T.Text -> Cell t m ()
textCell = cell . text

lazyTextCell :: DomBuilder t m => LT.Text -> Cell t m ()
lazyTextCell = textCell . LT.toStrict

builderCell :: DomBuilder t m => LT.Builder -> Cell t m ()
builderCell = textCell . LT.toStrict . LT.toLazyText

-- | This instance is requires @UndecidableInstances@ and is kind of
--   bad, but @reflex@ already abusing type classes so much that it
--   doesn\'t seem too terrible to add this to the mix.
instance (DomBuilder t m, a ~ ()) => IsString (Cell t m a) where
  fromString = stringCell

newtype WrappedApplicative m a = WrappedApplicative
  { unWrappedApplicative :: m a }
  deriving (Functor,Applicative,Monad)

instance (Semigroup a, Applicative m) => Semigroup (WrappedApplicative m a) where
  (WrappedApplicative m1) <> (WrappedApplicative m2) = WrappedApplicative (liftA2 (<>) m1 m2)

instance (Monoid a, Applicative m) => Monoid (WrappedApplicative m a) where
  mempty = WrappedApplicative (pure mempty)
  mappend (WrappedApplicative m1) (WrappedApplicative m2) = WrappedApplicative (liftA2 mappend m1 m2)

basic ::
  (DomBuilder t m, PostBuild t m, Foldable f)
  => M.Map T.Text T.Text -- ^ @\<table\>@ tag attributes
  -> Colonnade Headed a (Cell t m ()) -- ^ Data encoding strategy
  -> f a -- ^ Collection of data
  -> m ()
basic tableAttrs = static tableAttrs Nothing mempty (const mempty)

body :: (DomBuilder t m, PostBuild t m, Foldable f, Monoid e)
  => M.Map T.Text T.Text
  -> (a -> M.Map T.Text T.Text)
  -> Colonnade p a (Cell t m e)
  -> f a
  -> m e
body bodyAttrs trAttrs colonnade collection =
  elAttr "tbody" bodyAttrs . unWrappedApplicative . flip foldMap collection $ \a ->
    WrappedApplicative .
    elAttr "tr" (trAttrs a) .
    unWrappedApplicative $
    E.rowMonoidal colonnade (WrappedApplicative . elFromCell "td") a

static ::
  (DomBuilder t m, PostBuild t m, Foldable f, Foldable h, Monoid e)
  => M.Map T.Text T.Text -- ^ @\<table\>@ tag attributes
  -> Maybe (M.Map T.Text T.Text, M.Map T.Text T.Text)
  -- ^ Attributes of @\<thead\>@ and its @\<tr\>@, pass 'Nothing' to omit @\<thead\>@
  -> M.Map T.Text T.Text -- ^ @\<tbody\>@ tag attributes
  -> (a -> M.Map T.Text T.Text) -- ^ @\<tr\>@ tag attributes
  -> Colonnade h a (Cell t m e) -- ^ Data encoding strategy
  -> f a -- ^ Collection of data
  -> m e
static tableAttrs mheadAttrs bodyAttrs trAttrs colonnade collection =
  elAttr "table" tableAttrs $ do
    for_ mheadAttrs $ \(headAttrs,headTrAttrs) ->
      elAttr "thead" headAttrs . elAttr "tr" headTrAttrs $
        E.headerMonadicGeneral_ colonnade (elFromCell "th")
    body bodyAttrs trAttrs colonnade collection

encodeCorniceHead ::
  (DomBuilder t m, PostBuild t m, Monoid e)
  => M.Map T.Text T.Text
  -> Fascia p (M.Map T.Text T.Text)
  -> E.AnnotatedCornice p a (Cell t m e)
  -> m e
encodeCorniceHead headAttrs fascia annCornice =
  elAttr "thead" headAttrs (unWrappedApplicative thead)
  where thead = E.headersMonoidal (Just (fascia, addAttr)) [(th,id)] annCornice
        th size (Cell attrs contents) = WrappedApplicative (elDynAttr "th" (fmap addColspan attrs) contents)
          where addColspan = M.insert "colspan" (T.pack (show size))
        addAttr attrs = WrappedApplicative . elAttr "tr" attrs . unWrappedApplicative

capped ::
  (DomBuilder t m, PostBuild t m, MonadHold t m, Foldable f, Monoid e)
  => M.Map T.Text T.Text -- ^ @\<table\>@ tag attributes
  -> M.Map T.Text T.Text -- ^ @\<thead\>@ tag attributes
  -> M.Map T.Text T.Text -- ^ @\<tbody\>@ tag attributes
  -> (a -> M.Map T.Text T.Text) -- ^ @\<tr\>@ tag attributes
  -> Fascia p (M.Map T.Text T.Text) -- ^ Attributes for @\<tr\>@ elements in the @\<thead\>@
  -> Cornice p a (Cell t m e) -- ^ Data encoding strategy
  -> f a -- ^ Collection of data
  -> m e
capped tableAttrs headAttrs bodyAttrs trAttrs fascia cornice collection =
  elAttr "table" tableAttrs $ do
    h <- encodeCorniceHead headAttrs fascia (E.annotate cornice)
    b <- body bodyAttrs trAttrs (E.discard cornice) collection
    return (h `mappend` b)

bodyTraversing :: (DomBuilder t m, PostBuild t m, Traversable f, Monoid e)
  => M.Map T.Text T.Text
  -> (a -> M.Map T.Text T.Text)
  -> Colonnade p a (Cell t m e)
  -> f a
  -> m (f e)
bodyTraversing bodyAttrs trAttrs colonnade collection =
  elAttr "tbody" bodyAttrs . for collection $ \a ->
    elAttr "tr" (trAttrs a) .
    unWrappedApplicative $
    E.rowMonoidal colonnade (WrappedApplicative . elFromCell "td") a

cappedTraversing ::
  (DomBuilder t m, PostBuild t m, MonadHold t m, Traversable f, Monoid e)
  => M.Map T.Text T.Text -- ^ @\<table\>@ tag attributes
  -> M.Map T.Text T.Text -- ^ @\<thead\>@ tag attributes
  -> M.Map T.Text T.Text -- ^ @\<tbody\>@ tag attributes
  -> (a -> M.Map T.Text T.Text) -- ^ @\<tr\>@ tag attributes
  -> Fascia p (M.Map T.Text T.Text) -- ^ Attributes for @\<tr\>@ elements in the @\<thead\>@
  -> Cornice p a (Cell t m e) -- ^ Data encoding strategy
  -> f a -- ^ Collection of data
  -> m (f e)
cappedTraversing tableAttrs headAttrs bodyAttrs trAttrs fascia cornice collection =
  elAttr "table" tableAttrs $ do
    _ <- encodeCorniceHead headAttrs fascia (E.annotate cornice)
    b <- bodyTraversing bodyAttrs trAttrs (E.discard cornice) collection
    return b

dynamicBody :: (DomBuilder t m, PostBuild t m, Foldable f, Semigroup e, Monoid e)
  => Dynamic t (M.Map T.Text T.Text)
  -> (a -> M.Map T.Text T.Text)
  -> Colonnade p a (Cell t m e)
  -> Dynamic t (f a)
  -> m (Event t e)
dynamicBody bodyAttrs trAttrs colonnade dynCollection =
  elDynAttr "tbody" bodyAttrs . dyn . ffor dynCollection $ \collection ->
    unWrappedApplicative .
    flip foldMap collection $ \a ->
      WrappedApplicative .
      elAttr "tr" (trAttrs a) .
      unWrappedApplicative . E.rowMonoidal colonnade (WrappedApplicative . elFromCell "td") $ a

dynamic ::
  (DomBuilder t m, PostBuild t m, Foldable f, Foldable h, Semigroup e, Monoid e)
  => Dynamic t (M.Map T.Text T.Text) -- ^ @\<table\>@ tag attributes
  -> Maybe (Dynamic t (M.Map T.Text T.Text), Dynamic t (M.Map T.Text T.Text))
  -- ^ Attributes of @\<thead\>@ and its @\<tr\>@, pass 'Nothing' to omit @\<thead\>@
  -> Dynamic t (M.Map T.Text T.Text) -- ^ @\<tbody\>@ tag attributes
  -> (a -> M.Map T.Text T.Text) -- ^ @\<tr\>@ tag attributes
  -> Colonnade h a (Cell t m e) -- ^ Data encoding strategy
  -> Dynamic t (f a) -- ^ Collection of data
  -> m (Event t e)
dynamic tableAttrs mheadAttrs bodyAttrs trAttrs colonnade collection =
  elDynAttr "table" tableAttrs $ do
    for_ mheadAttrs $ \(headAttrs,headTrAttrs) ->
      elDynAttr "thead" headAttrs . elDynAttr "tr" headTrAttrs $
        E.headerMonadicGeneral_ colonnade (elFromCell "th")
    dynamicBody bodyAttrs trAttrs colonnade collection

encodeCorniceHeadDynamic ::
  (DomBuilder t m, PostBuild t m, Monoid e)
  => Dynamic t (M.Map T.Text T.Text)
  -> Fascia p (Dynamic t (M.Map T.Text T.Text))
  -> E.AnnotatedCornice p a (Cell t m e)
  -> m e
encodeCorniceHeadDynamic headAttrs fascia annCornice =
  elDynAttr "thead" headAttrs (unWrappedApplicative thead)
  where thead = E.headersMonoidal (Just (fascia, addAttr)) [(th,id)] annCornice
        th size (Cell attrs contents) = WrappedApplicative (elDynAttr "th" (fmap addColspan attrs) contents)
          where addColspan = M.insert "colspan" (T.pack (show size))
        addAttr attrs = WrappedApplicative . elDynAttr "tr" attrs . unWrappedApplicative

dynamicCapped ::
  (DomBuilder t m, PostBuild t m, MonadHold t m, Foldable f, Semigroup e, Monoid e)
  => Dynamic t (M.Map T.Text T.Text) -- ^ @\<table\>@ tag attributes
  -> Dynamic t (M.Map T.Text T.Text) -- ^ @\<thead\>@ tag attributes
  -> Dynamic t (M.Map T.Text T.Text) -- ^ @\<tbody\>@ tag attributes
  -> (a -> M.Map T.Text T.Text) -- ^ @\<tr\>@ tag attributes
  -> Fascia p (Dynamic t (M.Map T.Text T.Text)) -- ^ Attributes for @\<tr\>@ elements in the @\<thead\>@
  -> Cornice p a (Cell t m e) -- ^ Data encoding strategy
  -> Dynamic t (f a) -- ^ Collection of data
  -> m (Event t e)
dynamicCapped tableAttrs headAttrs bodyAttrs trAttrs fascia cornice collection =
  elDynAttr "table" tableAttrs $ do
    -- TODO: Figure out what this ignored argument represents and dont ignore it
    _ <- encodeCorniceHeadDynamic headAttrs fascia (E.annotate cornice)
    dynamicBody bodyAttrs trAttrs (E.discard cornice) collection
