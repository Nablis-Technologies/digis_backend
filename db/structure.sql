SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


--
-- Name: EXTENSION btree_gist; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: catalog_date_allocations_sum_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.catalog_date_allocations_sum_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF (
    SELECT COALESCE(SUM(allocation_basis_points), 0)
    FROM catalog_product_date_allocations
    WHERE event_product_id = NEW.event_product_id
  ) <> 10000 THEN
    RAISE EXCEPTION 'date allocations must sum to 10000 basis points for product %',
      NEW.event_product_id USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: consent_version_delete_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.consent_version_delete_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.status = 'draft' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'published or retired consent versions cannot be deleted'
    USING ERRCODE = '40001';
END;
$$;


--
-- Name: event_date_change_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_date_change_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'event date changes are append-only and cannot be modified or deleted'
    USING ERRCODE = '40001';
END;
$$;


--
-- Name: legal_version_delete_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.legal_version_delete_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.status = 'draft' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'published or retired legal versions cannot be deleted'
    USING ERRCODE = '40001';
END;
$$;


--
-- Name: lock_consent_version_on_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.lock_consent_version_on_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.status = 'draft' THEN
    RETURN NEW;
  END IF;
  IF (OLD.body, OLD.content_sha256, OLD.title, OLD.required,
      OLD.acceptance_scope, OLD.consent_document_id, OLD.created_by_id,
      OLD.version, OLD.published_at, OLD.published_by_id)
     IS DISTINCT FROM
     (NEW.body, NEW.content_sha256, NEW.title, NEW.required,
      NEW.acceptance_scope, NEW.consent_document_id, NEW.created_by_id,
      NEW.version, NEW.published_at, NEW.published_by_id) THEN
    RAISE EXCEPTION 'published or retired consent versions are immutable'
      USING ERRCODE = '40001';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: lock_legal_version_on_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.lock_legal_version_on_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.status = 'draft' THEN
    RETURN NEW;
  END IF;
  IF (OLD.body, OLD.commercial_policy_reference, OLD.content_sha256, OLD.title,
      OLD.legal_document_id, OLD.created_by_id, OLD.version,
      OLD.published_at, OLD.published_by_id)
     IS DISTINCT FROM
     (NEW.body, NEW.commercial_policy_reference, NEW.content_sha256, NEW.title,
      NEW.legal_document_id, NEW.created_by_id, NEW.version,
      NEW.published_at, NEW.published_by_id) THEN
    RAISE EXCEPTION 'published or retired legal versions are immutable'
      USING ERRCODE = '40001';
  END IF;
  RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: active_storage_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_attachments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying NOT NULL,
    record_type character varying NOT NULL,
    record_id uuid NOT NULL,
    blob_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL
);


--
-- Name: active_storage_blobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_blobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key character varying NOT NULL,
    filename character varying NOT NULL,
    content_type character varying,
    metadata text,
    service_name character varying NOT NULL,
    byte_size bigint NOT NULL,
    checksum character varying,
    created_at timestamp(6) with time zone NOT NULL
);


--
-- Name: active_storage_variant_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_variant_records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    blob_id uuid NOT NULL,
    variation_digest character varying NOT NULL
);


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: catalog_event_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_event_products (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    name character varying NOT NULL,
    description text,
    type character varying NOT NULL,
    allow_custom_price boolean DEFAULT false NOT NULL,
    sales_start_at timestamp with time zone,
    sales_end_at timestamp with time zone,
    min_per_order integer DEFAULT 1 NOT NULL,
    max_per_order integer,
    schedule_change_refund_policy character varying DEFAULT 'full_or_partial'::character varying NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    inventory_mode character varying DEFAULT 'unlimited'::character varying NOT NULL,
    idempotency_key character varying,
    idempotency_key_digest character varying(64),
    creation_request_digest character varying(64),
    CONSTRAINT catalog_event_products_creation_digests_check CHECK ((((idempotency_key_digest IS NULL) AND (creation_request_digest IS NULL)) OR (((idempotency_key_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((creation_request_digest)::text ~ '^[0-9a-f]{64}$'::text)))),
    CONSTRAINT catalog_event_products_inventory_mode_check CHECK (((inventory_mode)::text = ANY (ARRAY[('unlimited'::character varying)::text, ('event_wide'::character varying)::text, ('per_date'::character varying)::text, ('event_wide_and_per_date'::character varying)::text]))),
    CONSTRAINT catalog_event_products_max_per_order_check CHECK (((max_per_order IS NULL) OR (max_per_order >= min_per_order))),
    CONSTRAINT catalog_event_products_min_per_order_check CHECK ((min_per_order >= 1)),
    CONSTRAINT catalog_event_products_refund_policy_check CHECK (((schedule_change_refund_policy)::text = ANY (ARRAY[('full_or_partial'::character varying)::text, ('full_only'::character varying)::text]))),
    CONSTRAINT catalog_event_products_sales_window_check CHECK (((sales_end_at IS NULL) OR (sales_start_at IS NULL) OR (sales_end_at > sales_start_at))),
    CONSTRAINT catalog_event_products_status_check CHECK (((status)::text = ANY (ARRAY[('draft'::character varying)::text, ('active'::character varying)::text, ('retired'::character varying)::text]))),
    CONSTRAINT catalog_event_products_type_check CHECK (((type)::text = ANY (ARRAY[('ticket'::character varying)::text, ('parking'::character varying)::text, ('merchandise'::character varying)::text, ('food'::character varying)::text, ('donation'::character varying)::text, ('digital_addon'::character varying)::text, ('other'::character varying)::text])))
);


--
-- Name: catalog_exchange_rates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_exchange_rates (
    id uuid DEFAULT uuidv7() NOT NULL,
    from_currency character varying NOT NULL,
    to_currency character varying NOT NULL,
    rate numeric(24,12) NOT NULL,
    effective_from timestamp with time zone DEFAULT now() NOT NULL,
    effective_to timestamp with time zone,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT catalog_exchange_rates_from_currency_check CHECK (((from_currency)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT catalog_exchange_rates_rate_positive_check CHECK ((rate > (0)::numeric)),
    CONSTRAINT catalog_exchange_rates_to_currency_check CHECK (((to_currency)::text ~ '^[A-Z]{3}$'::text))
);


--
-- Name: catalog_inventory_reservations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_inventory_reservations (
    id uuid DEFAULT uuidv7() NOT NULL,
    product_inventory_id uuid NOT NULL,
    registration_id uuid,
    order_item_id uuid,
    reservation_group_id uuid NOT NULL,
    quantity integer NOT NULL,
    admissions_per_unit integer DEFAULT 1 NOT NULL,
    status character varying DEFAULT 'held'::character varying NOT NULL,
    expires_at timestamp with time zone,
    committed_at timestamp with time zone,
    released_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    request_fingerprint character varying(64) NOT NULL,
    CONSTRAINT catalog_inventory_reservations_admissions_check CHECK ((admissions_per_unit >= 1)),
    CONSTRAINT catalog_inventory_reservations_fingerprint_check CHECK (((request_fingerprint)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT catalog_inventory_reservations_owner_check CHECK ((NOT ((registration_id IS NOT NULL) AND (order_item_id IS NOT NULL)))),
    CONSTRAINT catalog_inventory_reservations_quantity_check CHECK ((quantity > 0)),
    CONSTRAINT catalog_inventory_reservations_status_check CHECK (((status)::text = ANY (ARRAY[('held'::character varying)::text, ('processing'::character varying)::text, ('committed'::character varying)::text, ('released'::character varying)::text, ('expired'::character varying)::text])))
);


--
-- Name: catalog_product_access_zones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_product_access_zones (
    id uuid DEFAULT uuidv7() NOT NULL,
    product_access_id uuid NOT NULL,
    access_zone_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: catalog_product_accesses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_product_accesses (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_product_id uuid NOT NULL,
    event_date_id uuid NOT NULL,
    type character varying NOT NULL,
    required_access_protection character varying,
    usage_limit integer,
    opens_offset_seconds integer,
    closes_offset_seconds integer,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT catalog_product_accesses_offset_check CHECK (((opens_offset_seconds IS NULL) OR (closes_offset_seconds IS NULL) OR ((closes_offset_seconds - opens_offset_seconds) > 0))),
    CONSTRAINT catalog_product_accesses_protection_check CHECK (((required_access_protection IS NULL) OR ((required_access_protection)::text = ANY ((ARRAY['public'::character varying, 'soft_gated'::character varying, 'signed'::character varying])::text[])))),
    CONSTRAINT catalog_product_accesses_protection_stream_check CHECK ((((required_access_protection IS NULL) AND ((type)::text <> 'stream'::text)) OR ((required_access_protection IS NOT NULL) AND ((type)::text = 'stream'::text)))),
    CONSTRAINT catalog_product_accesses_type_check CHECK (((type)::text = ANY ((ARRAY['venue'::character varying, 'stream'::character varying, 'parking'::character varying])::text[]))),
    CONSTRAINT catalog_product_accesses_usage_limit_check CHECK (((usage_limit > 0) OR (usage_limit IS NULL)))
);


--
-- Name: catalog_product_date_allocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_product_date_allocations (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_product_id uuid NOT NULL,
    event_date_id uuid NOT NULL,
    allocation_basis_points integer CONSTRAINT catalog_product_date_allocatio_allocation_basis_points_not_null NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT catalog_product_date_allocations_bps_range_check CHECK (((allocation_basis_points > 0) AND (allocation_basis_points <= 10000)))
);


--
-- Name: catalog_product_inventories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_product_inventories (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_product_id uuid NOT NULL,
    event_date_id uuid,
    capacity integer NOT NULL,
    held_count integer DEFAULT 0 NOT NULL,
    sold_count integer DEFAULT 0 NOT NULL,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT catalog_product_inventories_capacity_check CHECK ((capacity >= 0)),
    CONSTRAINT catalog_product_inventories_held_count_check CHECK ((held_count >= 0)),
    CONSTRAINT catalog_product_inventories_sold_count_check CHECK ((sold_count >= 0)),
    CONSTRAINT catalog_product_inventories_total_check CHECK (((held_count + sold_count) <= capacity))
);


--
-- Name: catalog_product_prices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_product_prices (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_product_id uuid NOT NULL,
    ticket_type_id uuid,
    currency character varying NOT NULL,
    amount_minor bigint NOT NULL,
    type character varying DEFAULT 'base'::character varying NOT NULL,
    active_from timestamp with time zone NOT NULL,
    active_to timestamp with time zone,
    active_range tstzrange GENERATED ALWAYS AS (tstzrange(active_from, active_to, '[]'::text)) STORED NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT catalog_product_prices_amount_check CHECK ((amount_minor >= 0)),
    CONSTRAINT catalog_product_prices_currency_check CHECK (((currency)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT catalog_product_prices_type_check CHECK (((type)::text = ANY (ARRAY[('base'::character varying)::text, ('override'::character varying)::text])))
);


--
-- Name: catalog_promotion_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_promotion_codes (
    id uuid DEFAULT uuidv7() NOT NULL,
    promotion_id uuid NOT NULL,
    code_digest character varying(64) NOT NULL,
    code_ciphertext text NOT NULL,
    label character varying,
    redemption_limit integer,
    starts_at timestamp with time zone,
    ends_at timestamp with time zone,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT catalog_promotion_codes_redemption_limit_check CHECK (((redemption_limit > 0) OR (redemption_limit IS NULL))),
    CONSTRAINT catalog_promotion_codes_window_check CHECK (((ends_at IS NULL) OR (starts_at IS NULL) OR (ends_at > starts_at)))
);


--
-- Name: catalog_promotion_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_promotion_products (
    id uuid DEFAULT uuidv7() NOT NULL,
    promotion_id uuid NOT NULL,
    event_product_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: catalog_promotions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_promotions (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    supersedes_promotion_id uuid,
    version integer DEFAULT 1 NOT NULL,
    name character varying NOT NULL,
    type character varying NOT NULL,
    percentage_basis_points integer,
    fixed_amount_minor bigint,
    currency character varying(3) NOT NULL,
    minimum_subtotal_minor bigint,
    maximum_discount_minor bigint,
    redemption_limit integer,
    per_user_limit integer DEFAULT 1 NOT NULL,
    starts_at timestamp with time zone,
    ends_at timestamp with time zone,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT catalog_promotions_calculation_check CHECK (((((type)::text = 'percentage'::text) AND (percentage_basis_points IS NOT NULL) AND (fixed_amount_minor IS NULL)) OR (((type)::text = 'fixed'::text) AND (fixed_amount_minor IS NOT NULL) AND (percentage_basis_points IS NULL)))),
    CONSTRAINT catalog_promotions_fixed_amount_check CHECK (((fixed_amount_minor >= 0) OR (fixed_amount_minor IS NULL))),
    CONSTRAINT catalog_promotions_maximum_discount_check CHECK (((maximum_discount_minor > 0) OR (maximum_discount_minor IS NULL))),
    CONSTRAINT catalog_promotions_minimum_subtotal_check CHECK (((minimum_subtotal_minor >= 0) OR (minimum_subtotal_minor IS NULL))),
    CONSTRAINT catalog_promotions_per_user_limit_check CHECK ((per_user_limit > 0)),
    CONSTRAINT catalog_promotions_percentage_check CHECK ((((percentage_basis_points >= 1) AND (percentage_basis_points <= 10000)) OR (percentage_basis_points IS NULL))),
    CONSTRAINT catalog_promotions_redemption_limit_check CHECK (((redemption_limit > 0) OR (redemption_limit IS NULL))),
    CONSTRAINT catalog_promotions_status_check CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'active'::character varying, 'disabled'::character varying])::text[]))),
    CONSTRAINT catalog_promotions_type_check CHECK (((type)::text = ANY ((ARRAY['percentage'::character varying, 'fixed'::character varying])::text[]))),
    CONSTRAINT catalog_promotions_window_check CHECK (((ends_at IS NULL) OR (starts_at IS NULL) OR (ends_at > starts_at)))
);


--
-- Name: catalog_venue_capacity_reservations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_venue_capacity_reservations (
    id uuid DEFAULT uuidv7() NOT NULL,
    reservation_group_id uuid CONSTRAINT catalog_venue_capacity_reservatio_reservation_group_id_not_null NOT NULL,
    event_date_id uuid NOT NULL,
    event_product_id uuid NOT NULL,
    registration_id uuid,
    order_item_id uuid,
    quantity_people integer NOT NULL,
    status character varying DEFAULT 'held'::character varying NOT NULL,
    expires_at timestamp with time zone,
    committed_at timestamp with time zone,
    released_at timestamp with time zone,
    request_fingerprint character varying(64) CONSTRAINT catalog_venue_capacity_reservation_request_fingerprint_not_null NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT catalog_venue_capacity_reservations_expiry_check CHECK ((((status)::text = ANY (ARRAY[('committed'::character varying)::text, ('released'::character varying)::text, ('expired'::character varying)::text])) OR (expires_at IS NOT NULL))),
    CONSTRAINT catalog_venue_capacity_reservations_fingerprint_check CHECK (((request_fingerprint)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT catalog_venue_capacity_reservations_owner_check CHECK ((NOT ((registration_id IS NOT NULL) AND (order_item_id IS NOT NULL)))),
    CONSTRAINT catalog_venue_capacity_reservations_quantity_check CHECK ((quantity_people > 0)),
    CONSTRAINT catalog_venue_capacity_reservations_status_check CHECK (((status)::text = ANY (ARRAY[('held'::character varying)::text, ('processing'::character varying)::text, ('committed'::character varying)::text, ('released'::character varying)::text, ('expired'::character varying)::text])))
);


--
-- Name: core_audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_audit_logs (
    id uuid DEFAULT uuidv7() NOT NULL,
    auditable_type character varying NOT NULL,
    auditable_id uuid NOT NULL,
    action character varying NOT NULL,
    audited_changes jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    actor_type character varying,
    actor_id uuid,
    request_uuid character varying,
    ip_address character varying,
    user_agent character varying,
    audit_key character varying NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: core_follows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_follows (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    follower_id uuid NOT NULL,
    followable_id uuid NOT NULL,
    followable_type character varying NOT NULL,
    followed_at timestamp(6) with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: core_outbox_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_outbox_events (
    id uuid DEFAULT uuidv7() NOT NULL,
    topic character varying NOT NULL,
    event_type character varying NOT NULL,
    aggregate_type character varying NOT NULL,
    aggregate_id uuid NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    idempotency_key character varying NOT NULL,
    occurred_at timestamp(6) with time zone NOT NULL,
    available_at timestamp(6) with time zone NOT NULL,
    published_at timestamp(6) with time zone,
    attempts integer DEFAULT 0 NOT NULL,
    last_error_code character varying,
    locked_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT core_outbox_events_aggregate_type_nonblank CHECK (((aggregate_type)::text <> ''::text)),
    CONSTRAINT core_outbox_events_available_after_occurred CHECK ((available_at >= occurred_at)),
    CONSTRAINT core_outbox_events_event_type_nonblank CHECK (((event_type)::text <> ''::text)),
    CONSTRAINT core_outbox_events_published_after_occurred CHECK (((published_at IS NULL) OR (published_at >= occurred_at))),
    CONSTRAINT core_outbox_events_topic_nonblank CHECK (((topic)::text <> ''::text))
);


--
-- Name: core_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_permissions (
    id uuid DEFAULT uuidv7() NOT NULL,
    code character varying(100) NOT NULL,
    resource character varying(50) NOT NULL,
    action character varying(50) NOT NULL,
    namespace character varying(50) DEFAULT 'core'::character varying NOT NULL,
    description character varying,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: core_refresh_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_refresh_tokens (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    token_fingerprint character varying NOT NULL,
    jti character varying NOT NULL,
    expires_at timestamp(6) with time zone NOT NULL,
    revoked boolean DEFAULT false NOT NULL,
    revoked_at timestamp(6) with time zone,
    device_id character varying,
    ip_address character varying,
    user_agent character varying,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: core_reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_reviews (
    id uuid DEFAULT uuidv7() NOT NULL,
    reviewable_type character varying NOT NULL,
    reviewable_id uuid NOT NULL,
    context character varying DEFAULT 'default'::character varying NOT NULL,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    feedback jsonb DEFAULT '{}'::jsonb NOT NULL,
    reviewed_by_type character varying,
    reviewed_by_id uuid,
    reviewed_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: core_role_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_role_permissions (
    id uuid DEFAULT uuidv7() NOT NULL,
    role_id uuid NOT NULL,
    permission_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: core_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_roles (
    id uuid DEFAULT uuidv7() NOT NULL,
    code character varying(50) NOT NULL,
    name character varying(100) NOT NULL,
    description character varying,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: core_user_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_user_roles (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    role_id uuid NOT NULL,
    assigned_by_id uuid,
    expires_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: core_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_users (
    id uuid DEFAULT uuidv7() NOT NULL,
    email character varying(150),
    phone character varying(30),
    verified_at timestamp(6) with time zone,
    password_digest character varying,
    deactivated_at timestamp(6) with time zone,
    deactivated_reason character varying,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: events_access_zones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_access_zones (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    event_date_id uuid,
    type character varying NOT NULL,
    name character varying NOT NULL,
    code character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT chk_access_zones_type CHECK (((type)::text = ANY (ARRAY[('venue'::character varying)::text, ('parking'::character varying)::text])))
);


--
-- Name: events_artists; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_artists (
    id uuid DEFAULT uuidv7() NOT NULL,
    name character varying NOT NULL,
    slug character varying NOT NULL,
    description text,
    image_url character varying,
    genres jsonb DEFAULT '[]'::jsonb,
    social_links jsonb DEFAULT '{}'::jsonb,
    verified boolean DEFAULT false,
    active boolean DEFAULT true,
    followers_count integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: events_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_categories (
    id uuid DEFAULT uuidv7() NOT NULL,
    name character varying NOT NULL,
    description character varying,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    slug character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: events_consent_document_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_consent_document_products (
    id uuid DEFAULT uuidv7() NOT NULL,
    consent_document_id uuid NOT NULL,
    ticket_type_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: events_consent_document_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_consent_document_versions (
    id uuid DEFAULT uuidv7() NOT NULL,
    consent_document_id uuid NOT NULL,
    version integer NOT NULL,
    title character varying NOT NULL,
    body text NOT NULL,
    content_sha256 character varying(64) NOT NULL,
    required boolean DEFAULT true NOT NULL,
    acceptance_scope character varying DEFAULT 'buyer'::character varying,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    published_by_id uuid,
    published_at timestamp without time zone,
    created_by_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT chk_consent_version_status CHECK (((status)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text])))
);


--
-- Name: events_consent_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_consent_documents (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    type character varying NOT NULL,
    name character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_by_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT chk_consent_doc_type CHECK (((type)::text = ANY (ARRAY[('terms'::character varying)::text, ('liability_waiver'::character varying)::text, ('media_consent'::character varying)::text, ('age_declaration'::character varying)::text, ('other'::character varying)::text])))
);


--
-- Name: events_event_cancellations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_event_cancellations (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    initiated_by_id uuid NOT NULL,
    reason text,
    attendee_reason text,
    status character varying DEFAULT 'initiated'::character varying NOT NULL,
    idempotency_key character varying NOT NULL,
    cancelled_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT chk_events_event_cancellations_cancelled_at CHECK ((cancelled_at IS NOT NULL)),
    CONSTRAINT chk_events_event_cancellations_status CHECK (((status)::text = ANY (ARRAY[('initiated'::character varying)::text, ('completed'::character varying)::text])))
);


--
-- Name: events_event_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_event_categories (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    category_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT chk_event_categories_present CHECK (((event_id IS NOT NULL) AND (category_id IS NOT NULL)))
);


--
-- Name: events_event_date_changes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_event_date_changes (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    event_date_id uuid NOT NULL,
    change_type character varying DEFAULT 'reschedule'::character varying NOT NULL,
    old_start_at timestamp with time zone NOT NULL,
    old_end_at timestamp with time zone NOT NULL,
    new_start_at timestamp with time zone NOT NULL,
    new_end_at timestamp with time zone NOT NULL,
    scheduled_by_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: events_event_dates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_event_dates (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    venue_id uuid,
    name character varying,
    doors_at timestamp with time zone,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone NOT NULL,
    status character varying DEFAULT 'scheduled'::character varying NOT NULL,
    venue_capacity integer,
    held_venue_count integer DEFAULT 0 NOT NULL,
    issued_venue_count integer DEFAULT 0 NOT NULL,
    source_key character varying,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT chk_event_dates_counts_nonnegative CHECK (((held_venue_count >= 0) AND (issued_venue_count >= 0))),
    CONSTRAINT chk_event_dates_doors_before_starts CHECK (((doors_at IS NULL) OR (doors_at <= starts_at))),
    CONSTRAINT chk_event_dates_ends_after_starts CHECK ((ends_at > starts_at))
);


--
-- Name: events_event_media; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_event_media (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    created_by_id uuid NOT NULL,
    type character varying NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    alt_text character varying,
    caption text,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT chk_event_media_cover_position CHECK ((((type)::text <> 'cover'::text) OR ("position" = 0))),
    CONSTRAINT chk_event_media_position CHECK (("position" >= 0)),
    CONSTRAINT chk_event_media_type CHECK (((type)::text = ANY (ARRAY[('cover'::character varying)::text, ('gallery'::character varying)::text])))
);


--
-- Name: events_event_organizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_event_organizations (
    id uuid DEFAULT uuidv7() NOT NULL,
    type character varying NOT NULL,
    event_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    role character varying DEFAULT 'collaborator'::character varying NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    invited_at timestamp with time zone,
    accepted_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT chk_event_organizations_no_primary_owner CHECK (((role)::text <> 'primary_owner'::text)),
    CONSTRAINT chk_event_organizations_status CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('active'::character varying)::text, ('revoked'::character varying)::text]))),
    CONSTRAINT chk_event_organizations_type CHECK (((type)::text = ANY (ARRAY[('co_organizer'::character varying)::text, ('venue_partner'::character varying)::text, ('promoter'::character varying)::text, ('sponsor'::character varying)::text])))
);


--
-- Name: events_event_participants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_event_participants (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    event_date_id uuid,
    artist_id uuid,
    name character varying NOT NULL,
    type character varying NOT NULL,
    description text,
    display_order integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT chk_event_participants_type CHECK (((type)::text = ANY (ARRAY[('performer'::character varying)::text, ('speaker'::character varying)::text, ('host'::character varying)::text, ('instructor'::character varying)::text, ('panelist'::character varying)::text, ('team'::character varying)::text, ('guest'::character varying)::text])))
);


--
-- Name: events_event_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_event_settings (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: events_event_staff_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_event_staff_assignments (
    id uuid DEFAULT uuidv7() NOT NULL,
    role character varying NOT NULL,
    event_id uuid NOT NULL,
    user_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    expires_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT chk_event_staff_assignments_role CHECK (((role)::text = ANY (ARRAY[('manager'::character varying)::text, ('staff'::character varying)::text, ('scanner'::character varying)::text, ('contractor'::character varying)::text]))),
    CONSTRAINT chk_event_staff_assignments_status CHECK (((status)::text = ANY (ARRAY[('active'::character varying)::text, ('suspended'::character varying)::text, ('revoked'::character varying)::text, ('expired'::character varying)::text])))
);


--
-- Name: events_event_streams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_event_streams (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_date_id uuid NOT NULL,
    provider character varying NOT NULL,
    provider_stream_id character varying,
    provider_playback_id character varying,
    access_protection character varying NOT NULL,
    status character varying DEFAULT 'scheduled'::character varying NOT NULL,
    live_from timestamp with time zone NOT NULL,
    live_until timestamp with time zone NOT NULL,
    replay_enabled boolean DEFAULT false NOT NULL,
    replay_available_until timestamp with time zone,
    max_concurrent_devices integer DEFAULT 1 NOT NULL,
    config jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT chk_event_streams_access_protection CHECK (((access_protection)::text = ANY (ARRAY[('public'::character varying)::text, ('soft_gated'::character varying)::text, ('signed'::character varying)::text]))),
    CONSTRAINT chk_event_streams_replay_until CHECK (((replay_available_until IS NOT NULL) OR (replay_enabled = false))),
    CONSTRAINT chk_event_streams_status CHECK (((status)::text = ANY (ARRAY[('scheduled'::character varying)::text, ('live'::character varying)::text, ('ended'::character varying)::text, ('disabled'::character varying)::text])))
);


--
-- Name: events_event_video_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_event_video_links (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    created_by_id uuid NOT NULL,
    provider character varying DEFAULT 'youtube'::character varying NOT NULL,
    url character varying NOT NULL,
    title character varying,
    caption text,
    "position" integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT chk_event_video_links_provider CHECK (((provider)::text = 'youtube'::text))
);


--
-- Name: events_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_events (
    id uuid DEFAULT uuidv7() NOT NULL,
    organization_id uuid NOT NULL,
    created_by_id uuid NOT NULL,
    slug character varying NOT NULL,
    title character varying NOT NULL,
    description text,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    visibility character varying DEFAULT 'private'::character varying NOT NULL,
    timezone character varying NOT NULL,
    currency character varying DEFAULT 'ETB'::character varying NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    published_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    discovery_refreshed_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT chk_events_events_cancelled_at_requires_cancelled CHECK (((cancelled_at IS NULL) OR ((status)::text = 'cancelled'::text))),
    CONSTRAINT chk_events_events_currency_iso4217 CHECK (((currency)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT chk_events_events_published_at_requires_published CHECK (((published_at IS NULL) OR ((status)::text = ANY (ARRAY['published'::text, 'cancelled'::text])))),
    CONSTRAINT chk_events_events_status CHECK (((status)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('cancelled'::character varying)::text, ('completed'::character varying)::text]))),
    CONSTRAINT chk_events_events_version_non_negative CHECK ((version >= 0)),
    CONSTRAINT chk_events_events_visibility CHECK (((visibility)::text = ANY (ARRAY[('private'::character varying)::text, ('public'::character varying)::text, ('unlisted'::character varying)::text])))
);


--
-- Name: events_recurrence_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_recurrence_rules (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    rrule text NOT NULL,
    timezone character varying NOT NULL,
    dtstart_local timestamp without time zone NOT NULL,
    duration_seconds integer NOT NULL,
    generated_until timestamp with time zone,
    active boolean DEFAULT true NOT NULL,
    exdates jsonb DEFAULT '[]'::jsonb NOT NULL,
    rdates jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT chk_recurrence_duration_positive CHECK ((duration_seconds > 0))
);


--
-- Name: events_venues; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events_venues (
    id uuid DEFAULT uuidv7() NOT NULL,
    name character varying NOT NULL,
    slug character varying NOT NULL,
    description text,
    address character varying,
    city character varying,
    country character varying,
    latitude numeric(10,6),
    longitude numeric(10,6),
    capacity integer,
    amenities jsonb DEFAULT '[]'::jsonb,
    social_links jsonb DEFAULT '{}'::jsonb,
    contact_phone character varying,
    contact_email character varying,
    website_url character varying,
    verified boolean DEFAULT false,
    active boolean DEFAULT true,
    followers_count integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: legal_acceptances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.legal_acceptances (
    id uuid DEFAULT uuidv7() NOT NULL,
    subject_type character varying NOT NULL,
    subject_id uuid NOT NULL,
    legal_document_version_id uuid NOT NULL,
    accepted_by_user_id uuid NOT NULL,
    acceptance_method character varying DEFAULT 'checkbox'::character varying NOT NULL,
    accepted_by_role character varying,
    content_sha256 character varying(64) NOT NULL,
    evidence_digest character varying(64) NOT NULL,
    request_uuid uuid NOT NULL,
    accepted_at timestamp(6) with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT chk_legal_acceptance_method CHECK (((acceptance_method)::text = ANY (ARRAY[('checkbox'::character varying)::text, ('otp'::character varying)::text]))),
    CONSTRAINT chk_legal_acceptance_subject_type CHECK (((subject_type)::text = ANY (ARRAY[('user'::character varying)::text, ('organization'::character varying)::text, ('order'::character varying)::text])))
);


--
-- Name: legal_document_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.legal_document_versions (
    id uuid DEFAULT uuidv7() NOT NULL,
    legal_document_id uuid NOT NULL,
    version integer NOT NULL,
    title character varying NOT NULL,
    body text NOT NULL,
    content_sha256 character varying(64) NOT NULL,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    commercial_policy_reference character varying,
    published_by_id uuid,
    published_at timestamp without time zone,
    created_by_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT chk_legal_version_status CHECK (((status)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('retired'::character varying)::text])))
);


--
-- Name: legal_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.legal_documents (
    id uuid DEFAULT uuidv7() NOT NULL,
    document_type character varying NOT NULL,
    internal_name character varying NOT NULL,
    jurisdiction_code character varying DEFAULT 'GLOBAL'::character varying NOT NULL,
    locale character varying DEFAULT 'en'::character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_by_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT chk_legal_doc_type CHECK (((document_type)::text = ANY (ARRAY[('platform_terms'::character varying)::text, ('privacy_policy'::character varying)::text, ('organizer_agreement'::character varying)::text, ('organizer_fee_schedule'::character varying)::text, ('buyer_purchase_terms'::character varying)::text])))
);


--
-- Name: organizations_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organizations_memberships (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    role character varying DEFAULT 'staff'::character varying NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: organizations_organizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organizations_organizations (
    id uuid DEFAULT uuidv7() NOT NULL,
    name character varying NOT NULL,
    slug character varying NOT NULL,
    description text,
    social_links jsonb DEFAULT '{}'::jsonb,
    followers_count integer DEFAULT 0 NOT NULL,
    organizer_type character varying NOT NULL,
    category character varying NOT NULL,
    contact_phone character varying,
    contact_email character varying,
    website_url character varying,
    tin_number character varying,
    address_line1 character varying,
    address_line2 character varying,
    city character varying,
    region character varying,
    estimated_audience character varying,
    event_frequency character varying,
    events_count integer DEFAULT 0 NOT NULL,
    archived boolean DEFAULT false NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: ticketing_access_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_access_codes (
    id uuid DEFAULT uuidv7() NOT NULL,
    ticket_type_id uuid NOT NULL,
    code_digest character varying NOT NULL,
    label character varying,
    max_uses integer,
    used_count integer DEFAULT 0 NOT NULL,
    max_quantity_per_use integer DEFAULT 1 NOT NULL,
    starts_at timestamp with time zone,
    expires_at timestamp with time zone,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_access_codes_max_quantity_check CHECK ((max_quantity_per_use >= 1)),
    CONSTRAINT ticketing_access_codes_max_uses_check CHECK (((max_uses IS NULL) OR (max_uses >= 1))),
    CONSTRAINT ticketing_access_codes_used_count_check CHECK ((used_count >= 0)),
    CONSTRAINT ticketing_access_codes_window_check CHECK (((expires_at IS NULL) OR (starts_at IS NULL) OR (expires_at > starts_at)))
);


--
-- Name: ticketing_invitations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_invitations (
    id uuid DEFAULT uuidv7() NOT NULL,
    ticket_type_id uuid NOT NULL,
    invited_user_id uuid,
    name character varying,
    email_ciphertext text,
    phone_ciphertext text,
    contact_digest character varying NOT NULL,
    token_digest character varying NOT NULL,
    allowed_quantity integer DEFAULT 1 NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    expires_at timestamp with time zone,
    accepted_at timestamp with time zone,
    created_by_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_invitations_allowed_quantity_check CHECK ((allowed_quantity >= 1)),
    CONSTRAINT ticketing_invitations_status_check CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('accepted'::character varying)::text, ('revoked'::character varying)::text, ('expired'::character varying)::text])))
);


--
-- Name: ticketing_ticket_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_ticket_types (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_product_id uuid NOT NULL,
    approval_mode character varying DEFAULT 'automatic'::character varying NOT NULL,
    audience character varying NOT NULL,
    date_selection character varying NOT NULL,
    waitlist_enabled boolean DEFAULT false NOT NULL,
    transferable boolean,
    transfer_cutoff_seconds_before_start integer DEFAULT 0 CONSTRAINT ticketing_ticket_types_transfer_cutoff_seconds_before__not_null NOT NULL,
    admissions_per_unit integer DEFAULT 1 NOT NULL,
    delegation_enabled boolean DEFAULT false NOT NULL,
    delegation_validation_mode character varying DEFAULT 'offline_allowed'::character varying NOT NULL,
    entry_validation_mode character varying DEFAULT 'qr'::character varying NOT NULL,
    max_packages_per_user integer,
    resale_enabled boolean DEFAULT false NOT NULL,
    resale_cutoff_seconds_before_start integer DEFAULT 0 CONSTRAINT ticketing_ticket_types_resale_cutoff_seconds_before_st_not_null NOT NULL,
    resale_price_cap_type character varying,
    resale_fixed_cap_minor bigint,
    resale_fixed_cap_currency character varying(3),
    resale_percentage_cap_bps integer,
    max_completed_resales integer DEFAULT 1 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_ticket_types_admissions_check CHECK ((admissions_per_unit > 0)),
    CONSTRAINT ticketing_ticket_types_approval_mode_check CHECK (((approval_mode)::text = ANY (ARRAY[('automatic'::character varying)::text, ('manual'::character varying)::text]))),
    CONSTRAINT ticketing_ticket_types_audience_check CHECK (((audience)::text = ANY (ARRAY[('public'::character varying)::text, ('access_code'::character varying)::text, ('invitation'::character varying)::text, ('code_or_invitation'::character varying)::text]))),
    CONSTRAINT ticketing_ticket_types_date_selection_check CHECK (((date_selection)::text = ANY (ARRAY[('fixed'::character varying)::text, ('choose_one'::character varying)::text]))),
    CONSTRAINT ticketing_ticket_types_delegation_mode_check CHECK (((delegation_validation_mode)::text = ANY (ARRAY[('offline_allowed'::character varying)::text, ('online_required'::character varying)::text]))),
    CONSTRAINT ticketing_ticket_types_entry_mode_check CHECK (((entry_validation_mode)::text = ANY (ARRAY[('qr'::character varying)::text, ('qr_and_id'::character varying)::text]))),
    CONSTRAINT ticketing_ticket_types_max_per_user_check CHECK (((max_packages_per_user IS NULL) OR (max_packages_per_user > 0))),
    CONSTRAINT ticketing_ticket_types_max_resales_check CHECK ((max_completed_resales > 0)),
    CONSTRAINT ticketing_ticket_types_resale_cap_check CHECK (((resale_price_cap_type IS NULL) OR (((resale_price_cap_type)::text = 'fixed'::text) AND (resale_fixed_cap_minor IS NOT NULL) AND (resale_fixed_cap_currency IS NOT NULL) AND (resale_percentage_cap_bps IS NULL)) OR (((resale_price_cap_type)::text = 'percentage'::text) AND (resale_percentage_cap_bps IS NOT NULL) AND (resale_fixed_cap_minor IS NULL) AND (resale_fixed_cap_currency IS NULL)))),
    CONSTRAINT ticketing_ticket_types_resale_cutoff_check CHECK ((resale_cutoff_seconds_before_start >= 0)),
    CONSTRAINT ticketing_ticket_types_transfer_cutoff_check CHECK ((transfer_cutoff_seconds_before_start >= 0))
);


--
-- Name: active_storage_attachments active_storage_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT active_storage_attachments_pkey PRIMARY KEY (id);


--
-- Name: active_storage_blobs active_storage_blobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs
    ADD CONSTRAINT active_storage_blobs_pkey PRIMARY KEY (id);


--
-- Name: active_storage_variant_records active_storage_variant_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT active_storage_variant_records_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: catalog_event_products catalog_event_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_event_products
    ADD CONSTRAINT catalog_event_products_pkey PRIMARY KEY (id);


--
-- Name: catalog_exchange_rates catalog_exchange_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_exchange_rates
    ADD CONSTRAINT catalog_exchange_rates_pkey PRIMARY KEY (id);


--
-- Name: catalog_inventory_reservations catalog_inventory_reservations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_inventory_reservations
    ADD CONSTRAINT catalog_inventory_reservations_pkey PRIMARY KEY (id);


--
-- Name: catalog_product_access_zones catalog_product_access_zones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_access_zones
    ADD CONSTRAINT catalog_product_access_zones_pkey PRIMARY KEY (id);


--
-- Name: catalog_product_accesses catalog_product_accesses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_accesses
    ADD CONSTRAINT catalog_product_accesses_pkey PRIMARY KEY (id);


--
-- Name: catalog_product_date_allocations catalog_product_date_allocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_date_allocations
    ADD CONSTRAINT catalog_product_date_allocations_pkey PRIMARY KEY (id);


--
-- Name: catalog_product_inventories catalog_product_inventories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_inventories
    ADD CONSTRAINT catalog_product_inventories_pkey PRIMARY KEY (id);


--
-- Name: catalog_product_prices catalog_product_prices_active_range_excl; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_prices
    ADD CONSTRAINT catalog_product_prices_active_range_excl EXCLUDE USING gist (event_product_id WITH =, COALESCE(ticket_type_id, '00000000-0000-0000-0000-000000000000'::uuid) WITH =, currency WITH =, active_range WITH &&);


--
-- Name: catalog_product_prices catalog_product_prices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_prices
    ADD CONSTRAINT catalog_product_prices_pkey PRIMARY KEY (id);


--
-- Name: catalog_promotion_codes catalog_promotion_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_promotion_codes
    ADD CONSTRAINT catalog_promotion_codes_pkey PRIMARY KEY (id);


--
-- Name: catalog_promotion_products catalog_promotion_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_promotion_products
    ADD CONSTRAINT catalog_promotion_products_pkey PRIMARY KEY (id);


--
-- Name: catalog_promotions catalog_promotions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_promotions
    ADD CONSTRAINT catalog_promotions_pkey PRIMARY KEY (id);


--
-- Name: catalog_venue_capacity_reservations catalog_venue_capacity_reservations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_venue_capacity_reservations
    ADD CONSTRAINT catalog_venue_capacity_reservations_pkey PRIMARY KEY (id);


--
-- Name: core_audit_logs core_audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_audit_logs
    ADD CONSTRAINT core_audit_logs_pkey PRIMARY KEY (id);


--
-- Name: core_follows core_follows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_follows
    ADD CONSTRAINT core_follows_pkey PRIMARY KEY (id);


--
-- Name: core_outbox_events core_outbox_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_outbox_events
    ADD CONSTRAINT core_outbox_events_pkey PRIMARY KEY (id);


--
-- Name: core_permissions core_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_permissions
    ADD CONSTRAINT core_permissions_pkey PRIMARY KEY (id);


--
-- Name: core_refresh_tokens core_refresh_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_refresh_tokens
    ADD CONSTRAINT core_refresh_tokens_pkey PRIMARY KEY (id);


--
-- Name: core_reviews core_reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_reviews
    ADD CONSTRAINT core_reviews_pkey PRIMARY KEY (id);


--
-- Name: core_role_permissions core_role_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_role_permissions
    ADD CONSTRAINT core_role_permissions_pkey PRIMARY KEY (id);


--
-- Name: core_roles core_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_roles
    ADD CONSTRAINT core_roles_pkey PRIMARY KEY (id);


--
-- Name: core_user_roles core_user_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_user_roles
    ADD CONSTRAINT core_user_roles_pkey PRIMARY KEY (id);


--
-- Name: core_users core_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_users
    ADD CONSTRAINT core_users_pkey PRIMARY KEY (id);


--
-- Name: events_access_zones events_access_zones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_access_zones
    ADD CONSTRAINT events_access_zones_pkey PRIMARY KEY (id);


--
-- Name: events_artists events_artists_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_artists
    ADD CONSTRAINT events_artists_pkey PRIMARY KEY (id);


--
-- Name: events_categories events_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_categories
    ADD CONSTRAINT events_categories_pkey PRIMARY KEY (id);


--
-- Name: events_consent_document_products events_consent_document_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_consent_document_products
    ADD CONSTRAINT events_consent_document_products_pkey PRIMARY KEY (id);


--
-- Name: events_consent_document_versions events_consent_document_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_consent_document_versions
    ADD CONSTRAINT events_consent_document_versions_pkey PRIMARY KEY (id);


--
-- Name: events_consent_documents events_consent_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_consent_documents
    ADD CONSTRAINT events_consent_documents_pkey PRIMARY KEY (id);


--
-- Name: events_event_cancellations events_event_cancellations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_cancellations
    ADD CONSTRAINT events_event_cancellations_pkey PRIMARY KEY (id);


--
-- Name: events_event_categories events_event_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_categories
    ADD CONSTRAINT events_event_categories_pkey PRIMARY KEY (id);


--
-- Name: events_event_date_changes events_event_date_changes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_date_changes
    ADD CONSTRAINT events_event_date_changes_pkey PRIMARY KEY (id);


--
-- Name: events_event_dates events_event_dates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_dates
    ADD CONSTRAINT events_event_dates_pkey PRIMARY KEY (id);


--
-- Name: events_event_media events_event_media_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_media
    ADD CONSTRAINT events_event_media_pkey PRIMARY KEY (id);


--
-- Name: events_event_organizations events_event_organizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_organizations
    ADD CONSTRAINT events_event_organizations_pkey PRIMARY KEY (id);


--
-- Name: events_event_participants events_event_participants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_participants
    ADD CONSTRAINT events_event_participants_pkey PRIMARY KEY (id);


--
-- Name: events_event_settings events_event_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_settings
    ADD CONSTRAINT events_event_settings_pkey PRIMARY KEY (id);


--
-- Name: events_event_staff_assignments events_event_staff_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_staff_assignments
    ADD CONSTRAINT events_event_staff_assignments_pkey PRIMARY KEY (id);


--
-- Name: events_event_streams events_event_streams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_streams
    ADD CONSTRAINT events_event_streams_pkey PRIMARY KEY (id);


--
-- Name: events_event_video_links events_event_video_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_video_links
    ADD CONSTRAINT events_event_video_links_pkey PRIMARY KEY (id);


--
-- Name: events_events events_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_events
    ADD CONSTRAINT events_events_pkey PRIMARY KEY (id);


--
-- Name: events_recurrence_rules events_recurrence_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_recurrence_rules
    ADD CONSTRAINT events_recurrence_rules_pkey PRIMARY KEY (id);


--
-- Name: events_venues events_venues_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_venues
    ADD CONSTRAINT events_venues_pkey PRIMARY KEY (id);


--
-- Name: legal_acceptances legal_acceptances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_acceptances
    ADD CONSTRAINT legal_acceptances_pkey PRIMARY KEY (id);


--
-- Name: legal_document_versions legal_document_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_document_versions
    ADD CONSTRAINT legal_document_versions_pkey PRIMARY KEY (id);


--
-- Name: legal_documents legal_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_documents
    ADD CONSTRAINT legal_documents_pkey PRIMARY KEY (id);


--
-- Name: organizations_memberships organizations_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations_memberships
    ADD CONSTRAINT organizations_memberships_pkey PRIMARY KEY (id);


--
-- Name: organizations_organizations organizations_organizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations_organizations
    ADD CONSTRAINT organizations_organizations_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: ticketing_access_codes ticketing_access_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_access_codes
    ADD CONSTRAINT ticketing_access_codes_pkey PRIMARY KEY (id);


--
-- Name: ticketing_invitations ticketing_invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_invitations
    ADD CONSTRAINT ticketing_invitations_pkey PRIMARY KEY (id);


--
-- Name: ticketing_ticket_types ticketing_ticket_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_ticket_types
    ADD CONSTRAINT ticketing_ticket_types_pkey PRIMARY KEY (id);


--
-- Name: idx_access_zones_on_product_and_zone; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_access_zones_on_product_and_zone ON public.catalog_product_access_zones USING btree (product_access_id, access_zone_id);


--
-- Name: idx_catalog_event_products_on_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_catalog_event_products_on_idempotency_key ON public.catalog_event_products USING btree (idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: idx_catalog_event_products_on_idempotency_key_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_catalog_event_products_on_idempotency_key_digest ON public.catalog_event_products USING btree (event_id, idempotency_key_digest) WHERE (idempotency_key_digest IS NOT NULL);


--
-- Name: idx_core_reviews_resource_context; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_core_reviews_resource_context ON public.core_reviews USING btree (reviewable_type, reviewable_id, context);


--
-- Name: idx_core_reviews_reviewer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_core_reviews_reviewer ON public.core_reviews USING btree (reviewed_by_type, reviewed_by_id);


--
-- Name: idx_date_allocations_on_product_and_date; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_date_allocations_on_product_and_date ON public.catalog_product_date_allocations USING btree (event_product_id, event_date_id);


--
-- Name: idx_events_events_lower_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_events_events_lower_slug ON public.events_events USING btree (lower((slug)::text));


--
-- Name: idx_inv_reservations_group_product_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_inv_reservations_group_product_unique ON public.catalog_inventory_reservations USING btree (reservation_group_id, product_inventory_id);


--
-- Name: idx_inventories_on_product_and_date; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_inventories_on_product_and_date ON public.catalog_product_inventories USING btree (event_product_id, event_date_id) WHERE (event_date_id IS NOT NULL);


--
-- Name: idx_inventories_on_product_where_date_null; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_inventories_on_product_where_date_null ON public.catalog_product_inventories USING btree (event_product_id) WHERE (event_date_id IS NULL);


--
-- Name: idx_inventory_reservations_on_status_and_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_inventory_reservations_on_status_and_expires ON public.catalog_inventory_reservations USING btree (status, expires_at);


--
-- Name: idx_legal_acceptances_by_actor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_legal_acceptances_by_actor ON public.legal_acceptances USING btree (accepted_by_user_id, accepted_at);


--
-- Name: idx_on_aggregate_type_aggregate_id_occurred_at_dc800603ae; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_aggregate_type_aggregate_id_occurred_at_dc800603ae ON public.core_outbox_events USING btree (aggregate_type, aggregate_id, occurred_at);


--
-- Name: idx_on_consent_document_id_ticket_type_id_73d6f9f9f0; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_consent_document_id_ticket_type_id_73d6f9f9f0 ON public.events_consent_document_products USING btree (consent_document_id, ticket_type_id);


--
-- Name: idx_on_event_id_organization_id_ee33770ea4; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_event_id_organization_id_ee33770ea4 ON public.events_event_organizations USING btree (event_id, organization_id);


--
-- Name: idx_on_event_id_status_sort_order_542594280f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_event_id_status_sort_order_542594280f ON public.catalog_event_products USING btree (event_id, status, sort_order);


--
-- Name: idx_on_event_id_user_id_role_75273129b3; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_event_id_user_id_role_75273129b3 ON public.events_event_staff_assignments USING btree (event_id, user_id, role);


--
-- Name: idx_on_published_at_available_at_id_30dbfe6ec6; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_published_at_available_at_id_30dbfe6ec6 ON public.core_outbox_events USING btree (published_at, available_at, id);


--
-- Name: idx_on_ticket_type_id_contact_digest_bd3fd90acf; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_ticket_type_id_contact_digest_bd3fd90acf ON public.ticketing_invitations USING btree (ticket_type_id, contact_digest);


--
-- Name: idx_one_owner_per_org; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_owner_per_org ON public.organizations_memberships USING btree (organization_id) WHERE ((role)::text = 'owner'::text);


--
-- Name: idx_org_memberships_on_user_and_org; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_org_memberships_on_user_and_org ON public.organizations_memberships USING btree (user_id, organization_id);


--
-- Name: idx_product_accesses_on_product_date_type; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_product_accesses_on_product_date_type ON public.catalog_product_accesses USING btree (event_product_id, event_date_id, type);


--
-- Name: idx_promotion_products_on_promotion_and_product; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_promotion_products_on_promotion_and_product ON public.catalog_promotion_products USING btree (promotion_id, event_product_id);


--
-- Name: idx_unique_legal_acceptance; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_unique_legal_acceptance ON public.legal_acceptances USING btree (subject_type, subject_id, legal_document_version_id);


--
-- Name: idx_unique_legal_acceptance_request_uuid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_unique_legal_acceptance_request_uuid ON public.legal_acceptances USING btree (request_uuid);


--
-- Name: idx_venue_capacity_reservations_on_group_and_date; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_venue_capacity_reservations_on_group_and_date ON public.catalog_venue_capacity_reservations USING btree (reservation_group_id, event_date_id);


--
-- Name: idx_venue_capacity_reservations_on_status_and_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_venue_capacity_reservations_on_status_and_expires ON public.catalog_venue_capacity_reservations USING btree (status, expires_at);


--
-- Name: index_access_zones_on_event_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_access_zones_on_event_code ON public.events_access_zones USING btree (event_id, code);


--
-- Name: index_access_zones_on_event_type_active_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_access_zones_on_event_type_active_order ON public.events_access_zones USING btree (event_id, type, active, sort_order);


--
-- Name: index_active_storage_attachments_on_blob_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_storage_attachments_on_blob_id ON public.active_storage_attachments USING btree (blob_id);


--
-- Name: index_active_storage_attachments_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_attachments_uniqueness ON public.active_storage_attachments USING btree (record_type, record_id, name, blob_id);


--
-- Name: index_active_storage_blobs_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_blobs_on_key ON public.active_storage_blobs USING btree (key);


--
-- Name: index_active_storage_variant_records_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_variant_records_uniqueness ON public.active_storage_variant_records USING btree (blob_id, variation_digest);


--
-- Name: index_catalog_exchange_rates_on_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_exchange_rates_on_active ON public.catalog_exchange_rates USING btree (active);


--
-- Name: index_catalog_exchange_rates_on_from_currency_and_to_currency; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_exchange_rates_on_from_currency_and_to_currency ON public.catalog_exchange_rates USING btree (from_currency, to_currency);


--
-- Name: index_catalog_inventory_reservations_on_order_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_inventory_reservations_on_order_item_id ON public.catalog_inventory_reservations USING btree (order_item_id);


--
-- Name: index_catalog_inventory_reservations_on_product_inventory_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_inventory_reservations_on_product_inventory_id ON public.catalog_inventory_reservations USING btree (product_inventory_id);


--
-- Name: index_catalog_inventory_reservations_on_registration_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_inventory_reservations_on_registration_id ON public.catalog_inventory_reservations USING btree (registration_id);


--
-- Name: index_catalog_product_access_zones_on_access_zone_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_product_access_zones_on_access_zone_id ON public.catalog_product_access_zones USING btree (access_zone_id);


--
-- Name: index_catalog_product_accesses_on_event_date_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_product_accesses_on_event_date_id ON public.catalog_product_accesses USING btree (event_date_id);


--
-- Name: index_catalog_product_inventories_on_event_date_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_product_inventories_on_event_date_id ON public.catalog_product_inventories USING btree (event_date_id);


--
-- Name: index_catalog_product_inventories_on_event_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_product_inventories_on_event_product_id ON public.catalog_product_inventories USING btree (event_product_id);


--
-- Name: index_catalog_product_prices_on_currency; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_product_prices_on_currency ON public.catalog_product_prices USING btree (currency);


--
-- Name: index_catalog_product_prices_on_event_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_product_prices_on_event_product_id ON public.catalog_product_prices USING btree (event_product_id);


--
-- Name: index_catalog_product_prices_on_ticket_type_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_product_prices_on_ticket_type_id ON public.catalog_product_prices USING btree (ticket_type_id);


--
-- Name: index_catalog_promotion_codes_on_code_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_catalog_promotion_codes_on_code_digest ON public.catalog_promotion_codes USING btree (code_digest);


--
-- Name: index_catalog_promotion_codes_on_promotion_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_promotion_codes_on_promotion_id ON public.catalog_promotion_codes USING btree (promotion_id);


--
-- Name: index_catalog_promotion_codes_on_promotion_id_and_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_promotion_codes_on_promotion_id_and_active ON public.catalog_promotion_codes USING btree (promotion_id, active);


--
-- Name: index_catalog_promotion_products_on_event_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_promotion_products_on_event_product_id ON public.catalog_promotion_products USING btree (event_product_id);


--
-- Name: index_catalog_promotions_on_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_promotions_on_event_id ON public.catalog_promotions USING btree (event_id);


--
-- Name: index_catalog_promotions_on_event_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_promotions_on_event_id_and_status ON public.catalog_promotions USING btree (event_id, status);


--
-- Name: index_catalog_promotions_on_event_id_and_version; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_promotions_on_event_id_and_version ON public.catalog_promotions USING btree (event_id, version);


--
-- Name: index_catalog_promotions_on_supersedes_promotion_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_promotions_on_supersedes_promotion_id ON public.catalog_promotions USING btree (supersedes_promotion_id);


--
-- Name: index_catalog_venue_capacity_reservations_on_event_date_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_venue_capacity_reservations_on_event_date_id ON public.catalog_venue_capacity_reservations USING btree (event_date_id);


--
-- Name: index_catalog_venue_capacity_reservations_on_event_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_venue_capacity_reservations_on_event_product_id ON public.catalog_venue_capacity_reservations USING btree (event_product_id);


--
-- Name: index_catalog_venue_capacity_reservations_on_order_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_venue_capacity_reservations_on_order_item_id ON public.catalog_venue_capacity_reservations USING btree (order_item_id);


--
-- Name: index_catalog_venue_capacity_reservations_on_registration_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_venue_capacity_reservations_on_registration_id ON public.catalog_venue_capacity_reservations USING btree (registration_id);


--
-- Name: index_consent_docs_on_event_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_consent_docs_on_event_name ON public.events_consent_documents USING btree (event_id, name);


--
-- Name: index_consent_versions_on_doc_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_consent_versions_on_doc_version ON public.events_consent_document_versions USING btree (consent_document_id, version);


--
-- Name: index_core_audit_logs_on_action; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_audit_logs_on_action ON public.core_audit_logs USING btree (action);


--
-- Name: index_core_audit_logs_on_actor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_audit_logs_on_actor ON public.core_audit_logs USING btree (actor_type, actor_id);


--
-- Name: index_core_audit_logs_on_audit_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_core_audit_logs_on_audit_key ON public.core_audit_logs USING btree (audit_key);


--
-- Name: index_core_audit_logs_on_auditable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_audit_logs_on_auditable ON public.core_audit_logs USING btree (auditable_type, auditable_id);


--
-- Name: index_core_audit_logs_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_audit_logs_on_created_at ON public.core_audit_logs USING btree (created_at);


--
-- Name: index_core_audit_logs_on_request_uuid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_audit_logs_on_request_uuid ON public.core_audit_logs USING btree (request_uuid);


--
-- Name: index_core_follows_on_follower_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_follows_on_follower_id ON public.core_follows USING btree (follower_id);


--
-- Name: index_core_outbox_events_on_event_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_outbox_events_on_event_type ON public.core_outbox_events USING btree (event_type);


--
-- Name: index_core_outbox_events_on_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_core_outbox_events_on_idempotency_key ON public.core_outbox_events USING btree (idempotency_key);


--
-- Name: index_core_permissions_on_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_permissions_on_active ON public.core_permissions USING btree (active);


--
-- Name: index_core_permissions_on_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_core_permissions_on_code ON public.core_permissions USING btree (code);


--
-- Name: index_core_permissions_on_namespace; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_permissions_on_namespace ON public.core_permissions USING btree (namespace);


--
-- Name: index_core_permissions_on_resource; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_permissions_on_resource ON public.core_permissions USING btree (resource);


--
-- Name: index_core_permissions_on_resource_action_namespace; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_core_permissions_on_resource_action_namespace ON public.core_permissions USING btree (resource, action, namespace);


--
-- Name: index_core_refresh_tokens_on_device_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_refresh_tokens_on_device_id ON public.core_refresh_tokens USING btree (device_id);


--
-- Name: index_core_refresh_tokens_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_refresh_tokens_on_expires_at ON public.core_refresh_tokens USING btree (expires_at);


--
-- Name: index_core_refresh_tokens_on_jti; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_core_refresh_tokens_on_jti ON public.core_refresh_tokens USING btree (jti);


--
-- Name: index_core_refresh_tokens_on_revoked; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_refresh_tokens_on_revoked ON public.core_refresh_tokens USING btree (revoked);


--
-- Name: index_core_refresh_tokens_on_token_fingerprint; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_core_refresh_tokens_on_token_fingerprint ON public.core_refresh_tokens USING btree (token_fingerprint);


--
-- Name: index_core_refresh_tokens_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_refresh_tokens_on_user_id ON public.core_refresh_tokens USING btree (user_id);


--
-- Name: index_core_reviews_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_reviews_on_status ON public.core_reviews USING btree (status);


--
-- Name: index_core_role_permissions_on_permission_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_role_permissions_on_permission_id ON public.core_role_permissions USING btree (permission_id);


--
-- Name: index_core_role_permissions_on_role_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_role_permissions_on_role_id ON public.core_role_permissions USING btree (role_id);


--
-- Name: index_core_role_permissions_on_role_id_and_permission_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_core_role_permissions_on_role_id_and_permission_id ON public.core_role_permissions USING btree (role_id, permission_id);


--
-- Name: index_core_roles_on_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_roles_on_active ON public.core_roles USING btree (active);


--
-- Name: index_core_roles_on_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_core_roles_on_code ON public.core_roles USING btree (code);


--
-- Name: index_core_user_roles_on_assigned_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_user_roles_on_assigned_by_id ON public.core_user_roles USING btree (assigned_by_id);


--
-- Name: index_core_user_roles_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_user_roles_on_expires_at ON public.core_user_roles USING btree (expires_at);


--
-- Name: index_core_user_roles_on_role_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_user_roles_on_role_id ON public.core_user_roles USING btree (role_id);


--
-- Name: index_core_user_roles_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_user_roles_on_user_id ON public.core_user_roles USING btree (user_id);


--
-- Name: index_core_user_roles_on_user_id_and_role_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_core_user_roles_on_user_id_and_role_id ON public.core_user_roles USING btree (user_id, role_id);


--
-- Name: index_core_users_on_deactivated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_users_on_deactivated_at ON public.core_users USING btree (deactivated_at);


--
-- Name: index_core_users_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_core_users_on_email ON public.core_users USING btree (email);


--
-- Name: index_core_users_on_phone; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_core_users_on_phone ON public.core_users USING btree (phone);


--
-- Name: index_event_media_on_created_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_event_media_on_created_by ON public.events_event_media USING btree (created_by_id);


--
-- Name: index_event_media_on_event_type_position; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_event_media_on_event_type_position ON public.events_event_media USING btree (event_id, type, "position");


--
-- Name: index_event_participants_on_artist_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_event_participants_on_artist_event ON public.events_event_participants USING btree (artist_id, event_id) WHERE (artist_id IS NOT NULL);


--
-- Name: index_event_participants_on_event_date_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_event_participants_on_event_date_order ON public.events_event_participants USING btree (event_id, event_date_id, display_order);


--
-- Name: index_event_streams_on_event_date; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_event_streams_on_event_date ON public.events_event_streams USING btree (event_date_id);


--
-- Name: index_event_video_links_on_event_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_event_video_links_on_event_position ON public.events_event_video_links USING btree (event_id, "position");


--
-- Name: index_events_artists_on_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_artists_on_active ON public.events_artists USING btree (active);


--
-- Name: index_events_artists_on_genres; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_artists_on_genres ON public.events_artists USING gin (genres);


--
-- Name: index_events_artists_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_events_artists_on_slug ON public.events_artists USING btree (slug);


--
-- Name: index_events_artists_on_verified; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_artists_on_verified ON public.events_artists USING btree (verified);


--
-- Name: index_events_categories_on_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_categories_on_active ON public.events_categories USING btree (active);


--
-- Name: index_events_categories_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_categories_on_name ON public.events_categories USING btree (name);


--
-- Name: index_events_categories_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_events_categories_on_slug ON public.events_categories USING btree (slug);


--
-- Name: index_events_event_cancellations_on_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_events_event_cancellations_on_event_id ON public.events_event_cancellations USING btree (event_id);


--
-- Name: index_events_event_cancellations_on_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_events_event_cancellations_on_idempotency_key ON public.events_event_cancellations USING btree (idempotency_key);


--
-- Name: index_events_event_cancellations_on_initiated_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_event_cancellations_on_initiated_by_id ON public.events_event_cancellations USING btree (initiated_by_id);


--
-- Name: index_events_event_categories_on_category_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_event_categories_on_category_id ON public.events_event_categories USING btree (category_id);


--
-- Name: index_events_event_categories_on_event_id_and_category_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_events_event_categories_on_event_id_and_category_id ON public.events_event_categories USING btree (event_id, category_id);


--
-- Name: index_events_event_date_changes_on_event_date_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_event_date_changes_on_event_date_id ON public.events_event_date_changes USING btree (event_date_id);


--
-- Name: index_events_event_date_changes_on_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_event_date_changes_on_event_id ON public.events_event_date_changes USING btree (event_id);


--
-- Name: index_events_event_date_changes_on_event_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_event_date_changes_on_event_id_and_created_at ON public.events_event_date_changes USING btree (event_id, created_at);


--
-- Name: index_events_event_dates_on_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_event_dates_on_event_id ON public.events_event_dates USING btree (event_id);


--
-- Name: index_events_event_dates_on_event_id_and_source_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_events_event_dates_on_event_id_and_source_key ON public.events_event_dates USING btree (event_id, source_key) WHERE (source_key IS NOT NULL);


--
-- Name: index_events_event_dates_on_event_id_and_starts_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_event_dates_on_event_id_and_starts_at ON public.events_event_dates USING btree (event_id, starts_at);


--
-- Name: index_events_event_organizations_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_event_organizations_on_organization_id ON public.events_event_organizations USING btree (organization_id);


--
-- Name: index_events_event_settings_on_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_events_event_settings_on_event_id ON public.events_event_settings USING btree (event_id);


--
-- Name: index_events_event_staff_assignments_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_event_staff_assignments_on_organization_id ON public.events_event_staff_assignments USING btree (organization_id);


--
-- Name: index_events_event_staff_assignments_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_event_staff_assignments_on_user_id ON public.events_event_staff_assignments USING btree (user_id);


--
-- Name: index_events_events_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_events_on_created_by_id ON public.events_events USING btree (created_by_id);


--
-- Name: index_events_events_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_events_on_organization_id ON public.events_events USING btree (organization_id);


--
-- Name: index_events_events_on_organization_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_events_on_organization_id_and_status ON public.events_events USING btree (organization_id, status);


--
-- Name: index_events_recurrence_rules_on_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_events_recurrence_rules_on_event_id ON public.events_recurrence_rules USING btree (event_id);


--
-- Name: index_events_venues_on_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_venues_on_active ON public.events_venues USING btree (active);


--
-- Name: index_events_venues_on_city; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_venues_on_city ON public.events_venues USING btree (city);


--
-- Name: index_events_venues_on_country; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_venues_on_country ON public.events_venues USING btree (country);


--
-- Name: index_events_venues_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_events_venues_on_slug ON public.events_venues USING btree (slug);


--
-- Name: index_events_venues_on_verified; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_venues_on_verified ON public.events_venues USING btree (verified);


--
-- Name: index_follows_followable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_follows_followable ON public.core_follows USING btree (followable_id, followable_type);


--
-- Name: index_follows_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_follows_uniqueness ON public.core_follows USING btree (follower_id, followable_id, followable_type);


--
-- Name: index_legal_docs_on_type_juris_locale; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_legal_docs_on_type_juris_locale ON public.legal_documents USING btree (document_type, jurisdiction_code, locale);


--
-- Name: index_legal_versions_on_doc_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_legal_versions_on_doc_version ON public.legal_document_versions USING btree (legal_document_id, version);


--
-- Name: index_one_published_legal_doc; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_one_published_legal_doc ON public.legal_document_versions USING btree (legal_document_id) WHERE ((status)::text = 'published'::text);


--
-- Name: index_one_published_version_per_doc; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_one_published_version_per_doc ON public.events_consent_document_versions USING btree (consent_document_id) WHERE ((status)::text = 'published'::text);


--
-- Name: index_organizations_memberships_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_organizations_memberships_on_organization_id ON public.organizations_memberships USING btree (organization_id);


--
-- Name: index_organizations_memberships_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_organizations_memberships_on_status ON public.organizations_memberships USING btree (status);


--
-- Name: index_organizations_memberships_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_organizations_memberships_on_user_id ON public.organizations_memberships USING btree (user_id);


--
-- Name: index_organizations_on_archived; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_organizations_on_archived ON public.organizations_organizations USING btree (archived);


--
-- Name: index_organizations_organizations_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_organizations_organizations_on_slug ON public.organizations_organizations USING btree (slug);


--
-- Name: index_ticketing_access_codes_on_ticket_type_id_and_code_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_access_codes_on_ticket_type_id_and_code_digest ON public.ticketing_access_codes USING btree (ticket_type_id, code_digest);


--
-- Name: index_ticketing_invitations_on_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_invitations_on_token_digest ON public.ticketing_invitations USING btree (token_digest);


--
-- Name: index_ticketing_ticket_types_on_event_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_ticket_types_on_event_product_id ON public.ticketing_ticket_types USING btree (event_product_id);


--
-- Name: events_consent_document_versions trg_consent_version_locked; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_consent_version_locked BEFORE UPDATE ON public.events_consent_document_versions FOR EACH ROW EXECUTE FUNCTION public.lock_consent_version_on_update();


--
-- Name: events_consent_document_versions trg_consent_version_nodelete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_consent_version_nodelete BEFORE DELETE ON public.events_consent_document_versions FOR EACH ROW EXECUTE FUNCTION public.consent_version_delete_guard();


--
-- Name: catalog_product_date_allocations trg_date_allocation_sum_check; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_date_allocation_sum_check AFTER INSERT OR UPDATE OF allocation_basis_points, event_product_id ON public.catalog_product_date_allocations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.catalog_date_allocations_sum_guard();


--
-- Name: events_event_date_changes trg_event_date_change_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_event_date_change_immutable BEFORE DELETE OR UPDATE ON public.events_event_date_changes FOR EACH ROW EXECUTE FUNCTION public.event_date_change_immutable();


--
-- Name: legal_document_versions trg_legal_version_locked; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_legal_version_locked BEFORE UPDATE ON public.legal_document_versions FOR EACH ROW EXECUTE FUNCTION public.lock_legal_version_on_update();


--
-- Name: legal_document_versions trg_legal_version_nodelete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_legal_version_nodelete BEFORE DELETE ON public.legal_document_versions FOR EACH ROW EXECUTE FUNCTION public.legal_version_delete_guard();


--
-- Name: events_recurrence_rules fk_rails_0311e23a95; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_recurrence_rules
    ADD CONSTRAINT fk_rails_0311e23a95 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE CASCADE;


--
-- Name: core_user_roles fk_rails_03c87b07c4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_user_roles
    ADD CONSTRAINT fk_rails_03c87b07c4 FOREIGN KEY (role_id) REFERENCES public.core_roles(id);


--
-- Name: catalog_product_date_allocations fk_rails_0586ee8b97; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_date_allocations
    ADD CONSTRAINT fk_rails_0586ee8b97 FOREIGN KEY (event_date_id) REFERENCES public.events_event_dates(id);


--
-- Name: events_events fk_rails_08a9375b27; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_events
    ADD CONSTRAINT fk_rails_08a9375b27 FOREIGN KEY (organization_id) REFERENCES public.organizations_organizations(id) ON DELETE RESTRICT;


--
-- Name: organizations_memberships fk_rails_0becb5aad6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations_memberships
    ADD CONSTRAINT fk_rails_0becb5aad6 FOREIGN KEY (user_id) REFERENCES public.core_users(id);


--
-- Name: legal_document_versions fk_rails_10caebc056; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_document_versions
    ADD CONSTRAINT fk_rails_10caebc056 FOREIGN KEY (published_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: events_event_date_changes fk_rails_116ec6066e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_date_changes
    ADD CONSTRAINT fk_rails_116ec6066e FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE CASCADE;


--
-- Name: catalog_product_access_zones fk_rails_15800e5abf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_access_zones
    ADD CONSTRAINT fk_rails_15800e5abf FOREIGN KEY (access_zone_id) REFERENCES public.events_access_zones(id);


--
-- Name: events_event_cancellations fk_rails_181e9ab2b0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_cancellations
    ADD CONSTRAINT fk_rails_181e9ab2b0 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE CASCADE;


--
-- Name: events_consent_document_versions fk_rails_1c88105b70; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_consent_document_versions
    ADD CONSTRAINT fk_rails_1c88105b70 FOREIGN KEY (consent_document_id) REFERENCES public.events_consent_documents(id) ON DELETE CASCADE;


--
-- Name: catalog_product_inventories fk_rails_1cac5a0ee8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_inventories
    ADD CONSTRAINT fk_rails_1cac5a0ee8 FOREIGN KEY (event_product_id) REFERENCES public.catalog_event_products(id);


--
-- Name: catalog_promotions fk_rails_1f9d62eca8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_promotions
    ADD CONSTRAINT fk_rails_1f9d62eca8 FOREIGN KEY (event_id) REFERENCES public.events_events(id);


--
-- Name: events_consent_documents fk_rails_29adff7b26; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_consent_documents
    ADD CONSTRAINT fk_rails_29adff7b26 FOREIGN KEY (created_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: core_user_roles fk_rails_29efe7500e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_user_roles
    ADD CONSTRAINT fk_rails_29efe7500e FOREIGN KEY (user_id) REFERENCES public.core_users(id);


--
-- Name: catalog_venue_capacity_reservations fk_rails_2e6172ce0c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_venue_capacity_reservations
    ADD CONSTRAINT fk_rails_2e6172ce0c FOREIGN KEY (event_product_id) REFERENCES public.catalog_event_products(id);


--
-- Name: catalog_product_date_allocations fk_rails_2eea671c63; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_date_allocations
    ADD CONSTRAINT fk_rails_2eea671c63 FOREIGN KEY (event_product_id) REFERENCES public.catalog_event_products(id);


--
-- Name: events_access_zones fk_rails_2f500dd95d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_access_zones
    ADD CONSTRAINT fk_rails_2f500dd95d FOREIGN KEY (event_date_id) REFERENCES public.events_event_dates(id) ON DELETE SET NULL;


--
-- Name: catalog_product_prices fk_rails_34242da597; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_prices
    ADD CONSTRAINT fk_rails_34242da597 FOREIGN KEY (ticket_type_id) REFERENCES public.ticketing_ticket_types(id);


--
-- Name: events_access_zones fk_rails_3543c09254; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_access_zones
    ADD CONSTRAINT fk_rails_3543c09254 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE CASCADE;


--
-- Name: catalog_promotion_products fk_rails_3a174a3c7f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_promotion_products
    ADD CONSTRAINT fk_rails_3a174a3c7f FOREIGN KEY (event_product_id) REFERENCES public.catalog_event_products(id);


--
-- Name: legal_acceptances fk_rails_3b2c4ebc36; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_acceptances
    ADD CONSTRAINT fk_rails_3b2c4ebc36 FOREIGN KEY (legal_document_version_id) REFERENCES public.legal_document_versions(id) ON DELETE RESTRICT;


--
-- Name: core_refresh_tokens fk_rails_3ed4f2d68b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_refresh_tokens
    ADD CONSTRAINT fk_rails_3ed4f2d68b FOREIGN KEY (user_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_access_codes fk_rails_46c5693101; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_access_codes
    ADD CONSTRAINT fk_rails_46c5693101 FOREIGN KEY (ticket_type_id) REFERENCES public.ticketing_ticket_types(id);


--
-- Name: legal_document_versions fk_rails_49e0e9421c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_document_versions
    ADD CONSTRAINT fk_rails_49e0e9421c FOREIGN KEY (created_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: events_consent_documents fk_rails_4ad8f14bf8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_consent_documents
    ADD CONSTRAINT fk_rails_4ad8f14bf8 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE CASCADE;


--
-- Name: events_event_media fk_rails_4cfe9ee26b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_media
    ADD CONSTRAINT fk_rails_4cfe9ee26b FOREIGN KEY (created_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: catalog_inventory_reservations fk_rails_520317750a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_inventory_reservations
    ADD CONSTRAINT fk_rails_520317750a FOREIGN KEY (product_inventory_id) REFERENCES public.catalog_product_inventories(id);


--
-- Name: events_consent_document_products fk_rails_520812941a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_consent_document_products
    ADD CONSTRAINT fk_rails_520812941a FOREIGN KEY (consent_document_id) REFERENCES public.events_consent_documents(id);


--
-- Name: catalog_promotions fk_rails_56d77862e4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_promotions
    ADD CONSTRAINT fk_rails_56d77862e4 FOREIGN KEY (supersedes_promotion_id) REFERENCES public.catalog_promotions(id);


--
-- Name: ticketing_invitations fk_rails_596dd5e6f4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_invitations
    ADD CONSTRAINT fk_rails_596dd5e6f4 FOREIGN KEY (created_by_id) REFERENCES public.core_users(id);


--
-- Name: core_follows fk_rails_5acb788933; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_follows
    ADD CONSTRAINT fk_rails_5acb788933 FOREIGN KEY (follower_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_ticket_types fk_rails_5e4a0f5f12; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_ticket_types
    ADD CONSTRAINT fk_rails_5e4a0f5f12 FOREIGN KEY (event_product_id) REFERENCES public.catalog_event_products(id);


--
-- Name: legal_document_versions fk_rails_5fe2791bee; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_document_versions
    ADD CONSTRAINT fk_rails_5fe2791bee FOREIGN KEY (legal_document_id) REFERENCES public.legal_documents(id) ON DELETE RESTRICT;


--
-- Name: events_event_streams fk_rails_6008354dda; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_streams
    ADD CONSTRAINT fk_rails_6008354dda FOREIGN KEY (event_date_id) REFERENCES public.events_event_dates(id) ON DELETE CASCADE;


--
-- Name: catalog_venue_capacity_reservations fk_rails_644ded3b72; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_venue_capacity_reservations
    ADD CONSTRAINT fk_rails_644ded3b72 FOREIGN KEY (event_date_id) REFERENCES public.events_event_dates(id);


--
-- Name: events_event_staff_assignments fk_rails_688c7d5175; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_staff_assignments
    ADD CONSTRAINT fk_rails_688c7d5175 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE CASCADE;


--
-- Name: events_event_participants fk_rails_7025684e48; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_participants
    ADD CONSTRAINT fk_rails_7025684e48 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE CASCADE;


--
-- Name: legal_acceptances fk_rails_73b4597b95; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_acceptances
    ADD CONSTRAINT fk_rails_73b4597b95 FOREIGN KEY (accepted_by_user_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: catalog_product_inventories fk_rails_774162eb7a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_inventories
    ADD CONSTRAINT fk_rails_774162eb7a FOREIGN KEY (event_date_id) REFERENCES public.events_event_dates(id);


--
-- Name: catalog_product_accesses fk_rails_77c2aaedcd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_accesses
    ADD CONSTRAINT fk_rails_77c2aaedcd FOREIGN KEY (event_date_id) REFERENCES public.events_event_dates(id);


--
-- Name: events_events fk_rails_784925b6cd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_events
    ADD CONSTRAINT fk_rails_784925b6cd FOREIGN KEY (created_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: catalog_event_products fk_rails_7bf2218d4e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_event_products
    ADD CONSTRAINT fk_rails_7bf2218d4e FOREIGN KEY (event_id) REFERENCES public.events_events(id);


--
-- Name: catalog_promotion_products fk_rails_7ef1b6f2d2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_promotion_products
    ADD CONSTRAINT fk_rails_7ef1b6f2d2 FOREIGN KEY (promotion_id) REFERENCES public.catalog_promotions(id);


--
-- Name: catalog_promotion_codes fk_rails_82ebe8867c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_promotion_codes
    ADD CONSTRAINT fk_rails_82ebe8867c FOREIGN KEY (promotion_id) REFERENCES public.catalog_promotions(id);


--
-- Name: organizations_memberships fk_rails_84f4e71154; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations_memberships
    ADD CONSTRAINT fk_rails_84f4e71154 FOREIGN KEY (organization_id) REFERENCES public.organizations_organizations(id);


--
-- Name: events_event_cancellations fk_rails_88de6f6294; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_cancellations
    ADD CONSTRAINT fk_rails_88de6f6294 FOREIGN KEY (initiated_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: events_event_staff_assignments fk_rails_89a4c0f504; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_staff_assignments
    ADD CONSTRAINT fk_rails_89a4c0f504 FOREIGN KEY (organization_id) REFERENCES public.organizations_organizations(id) ON DELETE CASCADE;


--
-- Name: events_event_categories fk_rails_8a7a3c0c11; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_categories
    ADD CONSTRAINT fk_rails_8a7a3c0c11 FOREIGN KEY (category_id) REFERENCES public.events_categories(id) ON DELETE RESTRICT;


--
-- Name: events_event_dates fk_rails_8e99dedcd1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_dates
    ADD CONSTRAINT fk_rails_8e99dedcd1 FOREIGN KEY (venue_id) REFERENCES public.events_venues(id) ON DELETE SET NULL;


--
-- Name: active_storage_variant_records fk_rails_993965df05; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT fk_rails_993965df05 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: events_consent_document_versions fk_rails_9b125d6d31; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_consent_document_versions
    ADD CONSTRAINT fk_rails_9b125d6d31 FOREIGN KEY (created_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: events_event_media fk_rails_a1b4824209; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_media
    ADD CONSTRAINT fk_rails_a1b4824209 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE CASCADE;


--
-- Name: core_role_permissions fk_rails_a1c6bb9a00; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_role_permissions
    ADD CONSTRAINT fk_rails_a1c6bb9a00 FOREIGN KEY (role_id) REFERENCES public.core_roles(id);


--
-- Name: events_event_dates fk_rails_acb9b776b1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_dates
    ADD CONSTRAINT fk_rails_acb9b776b1 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE CASCADE;


--
-- Name: core_role_permissions fk_rails_accabce058; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_role_permissions
    ADD CONSTRAINT fk_rails_accabce058 FOREIGN KEY (permission_id) REFERENCES public.core_permissions(id);


--
-- Name: events_event_video_links fk_rails_ad38a57f96; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_video_links
    ADD CONSTRAINT fk_rails_ad38a57f96 FOREIGN KEY (created_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: events_event_organizations fk_rails_ae4b4ed0bd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_organizations
    ADD CONSTRAINT fk_rails_ae4b4ed0bd FOREIGN KEY (organization_id) REFERENCES public.organizations_organizations(id) ON DELETE CASCADE;


--
-- Name: events_event_video_links fk_rails_b98836a298; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_video_links
    ADD CONSTRAINT fk_rails_b98836a298 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE CASCADE;


--
-- Name: legal_documents fk_rails_bd145f2b2b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_documents
    ADD CONSTRAINT fk_rails_bd145f2b2b FOREIGN KEY (created_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: catalog_product_prices fk_rails_bfffbd73ae; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_prices
    ADD CONSTRAINT fk_rails_bfffbd73ae FOREIGN KEY (event_product_id) REFERENCES public.catalog_event_products(id);


--
-- Name: active_storage_attachments fk_rails_c3b3935057; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT fk_rails_c3b3935057 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: events_event_settings fk_rails_c58f973380; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_settings
    ADD CONSTRAINT fk_rails_c58f973380 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE CASCADE;


--
-- Name: events_consent_document_products fk_rails_c649989cad; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_consent_document_products
    ADD CONSTRAINT fk_rails_c649989cad FOREIGN KEY (ticket_type_id) REFERENCES public.ticketing_ticket_types(id);


--
-- Name: ticketing_invitations fk_rails_ca5550ab7b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_invitations
    ADD CONSTRAINT fk_rails_ca5550ab7b FOREIGN KEY (ticket_type_id) REFERENCES public.ticketing_ticket_types(id);


--
-- Name: events_event_organizations fk_rails_ca5c06224a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_organizations
    ADD CONSTRAINT fk_rails_ca5c06224a FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE CASCADE;


--
-- Name: ticketing_invitations fk_rails_cc4a24abb3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_invitations
    ADD CONSTRAINT fk_rails_cc4a24abb3 FOREIGN KEY (invited_user_id) REFERENCES public.core_users(id);


--
-- Name: catalog_product_accesses fk_rails_d1fa2d2567; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_accesses
    ADD CONSTRAINT fk_rails_d1fa2d2567 FOREIGN KEY (event_product_id) REFERENCES public.catalog_event_products(id);


--
-- Name: events_event_date_changes fk_rails_d2b65b013d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_date_changes
    ADD CONSTRAINT fk_rails_d2b65b013d FOREIGN KEY (scheduled_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: core_user_roles fk_rails_e001d60739; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_user_roles
    ADD CONSTRAINT fk_rails_e001d60739 FOREIGN KEY (assigned_by_id) REFERENCES public.core_users(id);


--
-- Name: events_event_date_changes fk_rails_e0d0c7b105; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_date_changes
    ADD CONSTRAINT fk_rails_e0d0c7b105 FOREIGN KEY (event_date_id) REFERENCES public.events_event_dates(id) ON DELETE CASCADE;


--
-- Name: events_event_participants fk_rails_e185aded17; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_participants
    ADD CONSTRAINT fk_rails_e185aded17 FOREIGN KEY (event_date_id) REFERENCES public.events_event_dates(id) ON DELETE CASCADE;


--
-- Name: events_event_staff_assignments fk_rails_e3e6cd98cf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_staff_assignments
    ADD CONSTRAINT fk_rails_e3e6cd98cf FOREIGN KEY (user_id) REFERENCES public.core_users(id) ON DELETE CASCADE;


--
-- Name: events_consent_document_versions fk_rails_eca35bc8df; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_consent_document_versions
    ADD CONSTRAINT fk_rails_eca35bc8df FOREIGN KEY (published_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: events_event_categories fk_rails_f01a03d541; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_categories
    ADD CONSTRAINT fk_rails_f01a03d541 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE CASCADE;


--
-- Name: catalog_product_access_zones fk_rails_ffe7c83358; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_access_zones
    ADD CONSTRAINT fk_rails_ffe7c83358 FOREIGN KEY (product_access_id) REFERENCES public.catalog_product_accesses(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260801010003'),
('20260801010002'),
('20260801010001'),
('20260730010004'),
('20260730010003'),
('20260730010002'),
('20260730010001'),
('20260729000001'),
('20260728000004'),
('20260728000003'),
('20260728000002'),
('20260728000001'),
('20260727090024'),
('20260727090023'),
('20260727090022'),
('20260727090021'),
('20260727090020'),
('20260727090000'),
('20260726090003'),
('20260726090002'),
('20260726090001'),
('20260724090003'),
('20260724090002'),
('20260724090001'),
('20260717011002'),
('20260717011001'),
('20260717010900'),
('20260717010800'),
('20260717010700'),
('20260717010500'),
('20260717010400'),
('20260717010330'),
('20260717010300'),
('20260717010200'),
('20260717010100'),
('20260717000100'),
('20260530095119'),
('20260530000003'),
('20260530000002'),
('20260530000001'),
('20260525200001'),
('20260525200000'),
('20260521000000'),
('20260516000900'),
('20260516000800'),
('20260516000700'),
('20260516000600'),
('20260516000500'),
('20260516000400'),
('20260516000300'),
('20260516000200'),
('20260516000100');

