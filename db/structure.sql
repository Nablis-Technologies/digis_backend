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
-- Name: commercial_approval_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.commercial_approval_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'commercial_approval_append_only' USING ERRCODE = '40001';
END;
$$;


--
-- Name: commercial_event_payer_selection_integrity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.commercial_event_payer_selection_integrity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  component_event_product_id uuid;
  component_event_id uuid;
  component_default_payer text;
  component_allows_choice boolean;
BEGIN
  SELECT event_product_id, charged_to, organizer_payer_choice
    INTO component_event_product_id, component_default_payer, component_allows_choice
  FROM commercial_fee_components
  WHERE id = NEW.fee_component_id;

  IF component_event_product_id IS NOT NULL THEN
    SELECT event_id INTO component_event_id
    FROM catalog_event_products
    WHERE id = component_event_product_id;

    IF component_event_id IS DISTINCT FROM NEW.event_id THEN
      RAISE EXCEPTION 'commercial_event_payer_selection_event_scope' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.charged_to IS DISTINCT FROM component_default_payer AND NOT component_allows_choice THEN
    RAISE EXCEPTION 'commercial_event_payer_selection_forbidden' USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: commercial_fee_amount_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.commercial_fee_amount_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  old_status text;
  new_status text;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    SELECT version.status INTO old_status
    FROM commercial_fee_components component
    JOIN commercial_fee_schedule_versions version
      ON version.id = component.fee_schedule_version_id
    WHERE component.id = OLD.fee_component_id;
  END IF;
  IF TG_OP IN ('INSERT','UPDATE') THEN
    SELECT version.status INTO new_status
    FROM commercial_fee_components component
    JOIN commercial_fee_schedule_versions version
      ON version.id = component.fee_schedule_version_id
    WHERE component.id = NEW.fee_component_id;
  END IF;

  IF old_status IN ('approved','scheduled','active','superseded','expired','terminated') OR
     new_status IN ('approved','scheduled','active','superseded','expired','terminated') THEN
    RAISE EXCEPTION 'commercial_fee_definition_immutable' USING ERRCODE = '40001';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: commercial_fee_component_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.commercial_fee_component_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  old_status text;
  new_status text;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    SELECT status INTO old_status
    FROM commercial_fee_schedule_versions
    WHERE id = OLD.fee_schedule_version_id;
  END IF;
  IF TG_OP IN ('INSERT','UPDATE') THEN
    SELECT status INTO new_status
    FROM commercial_fee_schedule_versions
    WHERE id = NEW.fee_schedule_version_id;
  END IF;

  IF old_status IN ('approved','scheduled','active','superseded','expired','terminated') OR
     new_status IN ('approved','scheduled','active','superseded','expired','terminated') THEN
    RAISE EXCEPTION 'commercial_fee_definition_immutable' USING ERRCODE = '40001';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: commercial_fee_schedule_version_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.commercial_fee_schedule_version_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.status IN ('approved','scheduled','active','superseded','expired','terminated') THEN
    IF TG_OP = 'DELETE' THEN
      RAISE EXCEPTION 'commercial_fee_definition_immutable' USING ERRCODE = '40001';
    END IF;

    IF (OLD.fee_schedule_id, OLD.supersedes_version_id, OLD.version,
        OLD.definition_digest, OLD.legal_document_version_id,
        OLD.acceptance_policy, OLD.grandfather_until,
        OLD.effective_from, OLD.effective_until)
       IS DISTINCT FROM
       (NEW.fee_schedule_id, NEW.supersedes_version_id, NEW.version,
        NEW.definition_digest, NEW.legal_document_version_id,
        NEW.acceptance_policy, NEW.grandfather_until,
        NEW.effective_from, NEW.effective_until) THEN
      RAISE EXCEPTION 'commercial_fee_definition_immutable' USING ERRCODE = '40001';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: commercial_fee_tier_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.commercial_fee_tier_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  old_status text;
  new_status text;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    SELECT version.status INTO old_status
    FROM commercial_fee_components component
    JOIN commercial_fee_schedule_versions version
      ON version.id = component.fee_schedule_version_id
    WHERE component.id = OLD.fee_component_id;
  END IF;
  IF TG_OP IN ('INSERT','UPDATE') THEN
    SELECT version.status INTO new_status
    FROM commercial_fee_components component
    JOIN commercial_fee_schedule_versions version
      ON version.id = component.fee_schedule_version_id
    WHERE component.id = NEW.fee_component_id;
  END IF;

  IF old_status IN ('approved','scheduled','active','superseded','expired','terminated') OR
     new_status IN ('approved','scheduled','active','superseded','expired','terminated') THEN
    RAISE EXCEPTION 'commercial_fee_definition_immutable' USING ERRCODE = '40001';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: commercial_simulation_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.commercial_simulation_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'commercial_simulation_immutable' USING ERRCODE = '40001';
END;
$$;


--
-- Name: commercial_subsidy_reservation_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.commercial_subsidy_reservation_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status IN ('committed', 'released') THEN
      RAISE EXCEPTION 'commercial_subsidy_reservation_immutable' USING ERRCODE = '40001';
    END IF;

    RETURN OLD;
  END IF;

  IF (OLD.subsidy_budget_id, OLD.order_id, OLD.idempotency_key_digest,
      OLD.request_fingerprint, OLD.amount_minor, OLD.currency, OLD.expires_at)
     IS DISTINCT FROM
     (NEW.subsidy_budget_id, NEW.order_id, NEW.idempotency_key_digest,
      NEW.request_fingerprint, NEW.amount_minor, NEW.currency, NEW.expires_at) THEN
    RAISE EXCEPTION 'commercial_subsidy_reservation_immutable' USING ERRCODE = '40001';
  END IF;

  IF OLD.status IN ('committed', 'released') AND
     (OLD.status, OLD.committed_at, OLD.released_at) IS DISTINCT FROM
     (NEW.status, NEW.committed_at, NEW.released_at) THEN
    RAISE EXCEPTION 'commercial_subsidy_reservation_immutable' USING ERRCODE = '40001';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: commercial_volume_counter_scope(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.commercial_volume_counter_scope() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  event_organization_id uuid;
  component_event_product_id uuid;
  component_event_id uuid;
BEGIN
  IF NEW.event_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT organization_id INTO event_organization_id
  FROM events_events
  WHERE id = NEW.event_id;

  IF event_organization_id IS DISTINCT FROM NEW.organization_id THEN
    RAISE EXCEPTION 'commercial_volume_counter_scope' USING ERRCODE = '23514';
  END IF;

  SELECT event_product_id INTO component_event_product_id
  FROM commercial_fee_components
  WHERE id = NEW.fee_component_id;

  IF component_event_product_id IS NOT NULL THEN
    SELECT event_id INTO component_event_id
    FROM catalog_event_products
    WHERE id = component_event_product_id;

    IF component_event_id IS DISTINCT FROM NEW.event_id THEN
      RAISE EXCEPTION 'commercial_volume_counter_component_scope' USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: commercial_volume_usage_integrity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.commercial_volume_usage_integrity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  order_event_id uuid;
  order_organization_id uuid;
  order_currency text;
  order_status text;
  component_event_product_id uuid;
  component_event_id uuid;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'commercial_volume_usage_immutable' USING ERRCODE = '40001';
  END IF;

  SELECT orders.event_id, events.organization_id, orders.settlement_currency, orders.status
    INTO order_event_id, order_organization_id, order_currency, order_status
  FROM orders_orders orders
  JOIN events_events events ON events.id = orders.event_id
  WHERE orders.id = NEW.order_id;

  IF order_status NOT IN ('paid','fulfilled','partially_refunded','refunded') THEN
    RAISE EXCEPTION 'commercial_volume_usage_order_status' USING ERRCODE = '23514';
  END IF;

  IF order_organization_id IS DISTINCT FROM NEW.organization_id THEN
    RAISE EXCEPTION 'commercial_volume_usage_organization_scope' USING ERRCODE = '23514';
  END IF;

  IF NEW.window_type = 'event' AND NEW.event_id IS DISTINCT FROM order_event_id THEN
    RAISE EXCEPTION 'commercial_volume_usage_event_scope' USING ERRCODE = '23514';
  END IF;

  IF NEW.event_id IS NOT NULL AND NEW.event_id IS DISTINCT FROM order_event_id THEN
    RAISE EXCEPTION 'commercial_volume_usage_event_scope' USING ERRCODE = '23514';
  END IF;

  SELECT event_product_id INTO component_event_product_id
  FROM commercial_fee_components
  WHERE id = NEW.fee_component_id;

  IF component_event_product_id IS NOT NULL THEN
    SELECT event_id INTO component_event_id
    FROM catalog_event_products
    WHERE id = component_event_product_id;

    IF component_event_id IS DISTINCT FROM order_event_id THEN
      RAISE EXCEPTION 'commercial_volume_usage_component_scope' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.metric_type = 'accepted_gross' AND NEW.currency IS DISTINCT FROM order_currency THEN
    RAISE EXCEPTION 'commercial_volume_usage_currency_scope' USING ERRCODE = '23514';
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
-- Name: core_retention_policy_active_insert_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.core_retention_policy_active_insert_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.status = 'active' AND NEW.version <= (
    SELECT COALESCE(MAX(version), 0)
      FROM core_data_retention_policies
     WHERE category = NEW.category
       AND jurisdiction_code IS NOT DISTINCT FROM NEW.jurisdiction_code
  ) THEN
    RAISE EXCEPTION 'active retention policy versions must be monotonic'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: core_retention_policy_delete_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.core_retention_policy_delete_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.status = 'draft' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'active or retired retention policies cannot be deleted'
    USING ERRCODE = '40001';
END;
$$;


--
-- Name: core_retention_policy_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.core_retention_policy_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.status = 'draft' AND NEW.status = 'active' THEN
    IF NEW.version <= (
      SELECT COALESCE(MAX(version), 0)
        FROM core_data_retention_policies
       WHERE category = NEW.category
         AND jurisdiction_code IS NOT DISTINCT FROM NEW.jurisdiction_code
         AND id <> NEW.id
    ) THEN
      RAISE EXCEPTION 'active retention policy versions must be monotonic'
        USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;

  IF OLD.status = 'draft' THEN
    RETURN NEW;
  END IF;

  IF OLD.status = 'active' AND NEW.status = 'retired' THEN
    IF ROW(OLD.category, OLD.jurisdiction_code, OLD.version, OLD.retention_days,
           OLD.action, OLD.effective_at, OLD.created_by_id)
       IS DISTINCT FROM
       ROW(NEW.category, NEW.jurisdiction_code, NEW.version, NEW.retention_days,
           NEW.action, NEW.effective_at, NEW.created_by_id) THEN
      RAISE EXCEPTION 'active retention policies are immutable'
        USING ERRCODE = '40001';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status <> OLD.status OR
     ROW(OLD.category, OLD.jurisdiction_code, OLD.version, OLD.retention_days,
         OLD.action, OLD.effective_at, OLD.created_by_id)
     IS DISTINCT FROM
     ROW(NEW.category, NEW.jurisdiction_code, NEW.version, NEW.retention_days,
         NEW.action, NEW.effective_at, NEW.created_by_id) THEN
    RAISE EXCEPTION 'active or retired retention policies are immutable'
      USING ERRCODE = '40001';
  END IF;
  RETURN NEW;
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


--
-- Name: orders_order_adjustment_evidence_valid(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.orders_order_adjustment_evidence_valid(evidence jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
  evidence_key text;
BEGIN
  IF evidence IS NULL THEN
    RETURN TRUE;
  END IF;
  IF jsonb_typeof(evidence) <> 'object' THEN
    RETURN FALSE;
  END IF;

  FOR evidence_key IN SELECT jsonb_object_keys(evidence) LOOP
    IF evidence_key NOT IN ('scope','tier','window','rounding','explanation') THEN
      RETURN FALSE;
    END IF;
  END LOOP;
  RETURN TRUE;
END;
$$;


--
-- Name: orders_order_adjustment_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.orders_order_adjustment_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  old_order_status text;
  new_order_status text;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    SELECT status INTO old_order_status FROM orders_orders WHERE id = OLD.order_id;
  END IF;
  IF TG_OP <> 'DELETE' THEN
    SELECT status INTO new_order_status FROM orders_orders WHERE id = NEW.order_id;
  END IF;

  IF old_order_status IN ('pending_payment','paid','fulfilled','expired','cancelled','partially_refunded','refunded') OR
     new_order_status IN ('pending_payment','paid','fulfilled','expired','cancelled','partially_refunded','refunded') THEN
    RAISE EXCEPTION 'orders_order_adjustment_immutable' USING ERRCODE = '40001';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: orders_order_adjustment_integrity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.orders_order_adjustment_integrity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  order_currency text;
BEGIN
  SELECT charge_currency INTO order_currency
  FROM orders_orders
  WHERE id = NEW.order_id;

  IF order_currency IS DISTINCT FROM NEW.currency THEN
    RAISE EXCEPTION 'orders_order_adjustment_currency_scope' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: orders_order_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.orders_order_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.status IN ('pending_payment','paid','fulfilled','expired','cancelled','partially_refunded','refunded') OR
     (TG_OP <> 'DELETE' AND NEW.status IN ('pending_payment','paid','fulfilled','expired','cancelled','partially_refunded','refunded')) THEN
    IF TG_OP = 'DELETE' THEN
      RAISE EXCEPTION 'orders_order_snapshot_immutable' USING ERRCODE = '40001';
    END IF;

    IF (OLD.event_id, OLD.buyer_user_id, OLD.sales_channel, OLD.initiated_by_id,
        OLD.replaces_order_id, OLD.charge_currency, OLD.subtotal_minor,
        OLD.discount_minor, OLD.subsidy_minor, OLD.fee_minor, OLD.tax_minor,
        OLD.adjustment_minor, OLD.total_minor, OLD.settlement_currency,
        OLD.settlement_total_minor, OLD.exchange_rate, OLD.exchange_rate_source,
        OLD.exchange_rate_quoted_at, OLD.exchange_rate_expires_at, OLD.expires_at,
        OLD.idempotency_key_digest, OLD.creation_request_digest)
       IS DISTINCT FROM
       (NEW.event_id, NEW.buyer_user_id, NEW.sales_channel, NEW.initiated_by_id,
        NEW.replaces_order_id, NEW.charge_currency, NEW.subtotal_minor,
        NEW.discount_minor, NEW.subsidy_minor, NEW.fee_minor, NEW.tax_minor,
        NEW.adjustment_minor, NEW.total_minor, NEW.settlement_currency,
        NEW.settlement_total_minor, NEW.exchange_rate, NEW.exchange_rate_source,
        NEW.exchange_rate_quoted_at, NEW.exchange_rate_expires_at, NEW.expires_at,
        NEW.idempotency_key_digest, NEW.creation_request_digest) THEN
      RAISE EXCEPTION 'orders_order_snapshot_immutable' USING ERRCODE = '40001';
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: orders_order_item_event_scope(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.orders_order_item_event_scope() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  order_event_id uuid;
  product_event_id uuid;
  product_type text;
  registration_event_id uuid;
BEGIN
  SELECT event_id INTO order_event_id
  FROM orders_orders
  WHERE id = NEW.order_id;

  SELECT event_id, type INTO product_event_id, product_type
  FROM catalog_event_products
  WHERE id = NEW.event_product_id;

  IF order_event_id IS DISTINCT FROM product_event_id OR
     product_type IS DISTINCT FROM NEW.type_snapshot THEN
    RAISE EXCEPTION 'orders_order_item_event_scope' USING ERRCODE = '23514';
  END IF;

  IF NEW.registration_id IS NOT NULL THEN
    SELECT event_id INTO registration_event_id
    FROM ticketing_registrations
    WHERE id = NEW.registration_id;

    IF order_event_id IS DISTINCT FROM registration_event_id THEN
      RAISE EXCEPTION 'orders_order_item_registration_event_scope'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: orders_order_item_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.orders_order_item_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  old_order_status text;
  new_order_status text;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    SELECT status INTO old_order_status FROM orders_orders WHERE id = OLD.order_id;
  END IF;
  IF TG_OP <> 'DELETE' THEN
    SELECT status INTO new_order_status FROM orders_orders WHERE id = NEW.order_id;
  END IF;

  IF old_order_status IN ('pending_payment','paid','fulfilled','expired','cancelled','partially_refunded','refunded') OR
     new_order_status IN ('pending_payment','paid','fulfilled','expired','cancelled','partially_refunded','refunded') THEN
    IF TG_OP IN ('INSERT', 'DELETE') THEN
      RAISE EXCEPTION 'orders_order_item_snapshot_immutable' USING ERRCODE = '40001';
    END IF;

    IF (OLD.order_id, OLD.event_product_id, OLD.registration_id,
        OLD.resale_listing_id, OLD.name_snapshot, OLD.type_snapshot, OLD.quantity,
        OLD.admissions_per_unit_snapshot, OLD.base_currency,
        OLD.base_unit_amount_minor, OLD.charge_currency,
        OLD.charge_unit_amount_minor, OLD.exchange_rate, OLD.discount_minor,
        OLD.total_minor)
       IS DISTINCT FROM
       (NEW.order_id, NEW.event_product_id, NEW.registration_id,
        NEW.resale_listing_id, NEW.name_snapshot, NEW.type_snapshot, NEW.quantity,
        NEW.admissions_per_unit_snapshot, NEW.base_currency,
        NEW.base_unit_amount_minor, NEW.charge_currency,
        NEW.charge_unit_amount_minor, NEW.exchange_rate, NEW.discount_minor,
        NEW.total_minor) THEN
      RAISE EXCEPTION 'orders_order_item_snapshot_immutable' USING ERRCODE = '40001';
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: orders_payment_snapshot_integrity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.orders_payment_snapshot_integrity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  expected_amount bigint;
  expected_currency text;
BEGIN
  SELECT total_minor, charge_currency
    INTO expected_amount, expected_currency
  FROM orders_orders
  WHERE id = NEW.order_id;

  IF NOT FOUND OR NEW.amount_minor IS DISTINCT FROM expected_amount OR
     NEW.currency IS DISTINCT FROM expected_currency THEN
    RAISE EXCEPTION 'orders_payment_order_amount_currency_mismatch'
      USING ERRCODE = '23514';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM orders_payments
    WHERE order_id = NEW.order_id
      AND id IS DISTINCT FROM NEW.id
      AND commercial_signature IS DISTINCT FROM NEW.commercial_signature
  ) THEN
    RAISE EXCEPTION 'orders_payment_commercial_signature_mismatch'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: orders_promotion_redemption_scope(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.orders_promotion_redemption_scope() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  order_event_id uuid;
  order_buyer_id uuid;
  order_currency text;
  promotion_event_id uuid;
  code_promotion_id uuid;
BEGIN
  SELECT event_id, buyer_user_id, charge_currency
    INTO order_event_id, order_buyer_id, order_currency
  FROM orders_orders
  WHERE id = NEW.order_id;
  SELECT event_id INTO promotion_event_id
  FROM catalog_promotions
  WHERE id = NEW.promotion_id;

  IF order_event_id IS DISTINCT FROM promotion_event_id OR
     order_buyer_id IS DISTINCT FROM NEW.user_id OR
     order_currency IS DISTINCT FROM NEW.currency THEN
    RAISE EXCEPTION 'orders_promotion_redemption_scope' USING ERRCODE = '23514';
  END IF;

  IF NEW.promotion_code_id IS NOT NULL THEN
    SELECT promotion_id INTO code_promotion_id
    FROM catalog_promotion_codes
    WHERE id = NEW.promotion_code_id;

    IF code_promotion_id IS DISTINCT FROM NEW.promotion_id THEN
      RAISE EXCEPTION 'orders_promotion_redemption_code_scope'
        USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: orders_refund_integrity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.orders_refund_integrity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  payment_status text;
  accepted_at timestamptz;
  payment_amount bigint;
  payment_currency text;
BEGIN
  SELECT payments.status, payments.accepted_at, payments.amount_minor, payments.currency
    INTO payment_status, accepted_at, payment_amount, payment_currency
  FROM orders_payments AS payments
  WHERE payments.id = NEW.payment_id;

  IF NEW.type = 'payment_reversal' AND
     (payment_status IS DISTINCT FROM 'succeeded' OR accepted_at IS NOT NULL OR
      NEW.amount_minor IS DISTINCT FROM payment_amount OR
      NEW.currency IS DISTINCT FROM payment_currency) THEN
    RAISE EXCEPTION 'orders_payment_reversal_integrity' USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: registration_answer_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.registration_answer_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.erased_at IS NOT NULL THEN
    IF ROW(OLD.registration_form_submission_id, OLD.registration_question_id,
           OLD.question_key_snapshot, OLD.question_type_snapshot,
           OLD.response_scope_snapshot, OLD.question_label_snapshot,
           OLD.package_unit_number, OLD.admission_position, OLD.admission_slot_id,
           OLD.answer_ciphertext, OLD.retention_policy_id, OLD.retain_until,
           OLD.answered_at, OLD.erased_at, OLD.erasure_reason)
       IS DISTINCT FROM
       ROW(NEW.registration_form_submission_id, NEW.registration_question_id,
           NEW.question_key_snapshot, NEW.question_type_snapshot,
           NEW.response_scope_snapshot, NEW.question_label_snapshot,
           NEW.package_unit_number, NEW.admission_position, NEW.admission_slot_id,
           NEW.answer_ciphertext, NEW.retention_policy_id, NEW.retain_until,
           NEW.answered_at, NEW.erased_at, NEW.erasure_reason) THEN
      RAISE EXCEPTION 'erased registration answers are immutable'
        USING ERRCODE = '40001';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.erased_at IS NULL AND NEW.erasure_reason IS NULL AND
     NEW.answer_ciphertext IS NOT DISTINCT FROM OLD.answer_ciphertext AND
     (OLD.admission_slot_id IS NULL OR
      NEW.admission_slot_id IS NOT DISTINCT FROM OLD.admission_slot_id) AND
     ROW(OLD.registration_form_submission_id, OLD.registration_question_id,
         OLD.question_key_snapshot, OLD.question_type_snapshot,
         OLD.response_scope_snapshot, OLD.question_label_snapshot,
         OLD.package_unit_number, OLD.admission_position, OLD.retention_policy_id,
         OLD.retain_until, OLD.answered_at, OLD.erased_at, OLD.erasure_reason)
     IS NOT DISTINCT FROM
     ROW(NEW.registration_form_submission_id, NEW.registration_question_id,
         NEW.question_key_snapshot, NEW.question_type_snapshot,
         NEW.response_scope_snapshot, NEW.question_label_snapshot,
         NEW.package_unit_number, NEW.admission_position, NEW.retention_policy_id,
         NEW.retain_until, NEW.answered_at, NEW.erased_at, NEW.erasure_reason) THEN
    RETURN NEW;
  END IF;

  IF NEW.erased_at IS NOT NULL AND NEW.erasure_reason IS NOT NULL AND
     NEW.answer_ciphertext IS NULL AND
     (OLD.admission_slot_id IS NULL OR
      NEW.admission_slot_id IS NOT DISTINCT FROM OLD.admission_slot_id) AND
     ROW(OLD.registration_form_submission_id, OLD.registration_question_id,
         OLD.question_key_snapshot, OLD.question_type_snapshot,
         OLD.response_scope_snapshot, OLD.question_label_snapshot,
         OLD.package_unit_number, OLD.admission_position, OLD.retention_policy_id,
         OLD.retain_until, OLD.answered_at)
     IS NOT DISTINCT FROM
     ROW(NEW.registration_form_submission_id, NEW.registration_question_id,
         NEW.question_key_snapshot, NEW.question_type_snapshot,
         NEW.response_scope_snapshot, NEW.question_label_snapshot,
         NEW.package_unit_number, NEW.admission_position, NEW.retention_policy_id,
         NEW.retain_until, NEW.answered_at) THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'registration answers are append-only except issuance and erasure'
    USING ERRCODE = '40001';
END;
$$;


--
-- Name: registration_answer_delete_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.registration_answer_delete_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'registration answers cannot be deleted'
    USING ERRCODE = '40001';
END;
$$;


--
-- Name: registration_answer_revision_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.registration_answer_revision_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.erased_at IS NOT NULL THEN
     IF ROW(OLD.registration_answer_id, OLD.revision_number, OLD.answer_ciphertext,
            OLD.revised_by_id, OLD.source, OLD.reason_code, OLD.idempotency_key_digest,
            OLD.request_digest, OLD.revised_at, OLD.retain_until, OLD.erased_at)
        IS DISTINCT FROM
        ROW(NEW.registration_answer_id, NEW.revision_number, NEW.answer_ciphertext,
            NEW.revised_by_id, NEW.source, NEW.reason_code, NEW.idempotency_key_digest,
            NEW.request_digest, NEW.revised_at, NEW.retain_until, NEW.erased_at) THEN
      RAISE EXCEPTION 'erased answer revisions are immutable'
        USING ERRCODE = '40001';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.erased_at IS NULL AND NEW.answer_ciphertext IS NOT DISTINCT FROM OLD.answer_ciphertext AND
     ROW(OLD.registration_answer_id, OLD.revision_number, OLD.revised_by_id,
          OLD.source, OLD.reason_code, OLD.idempotency_key_digest, OLD.request_digest,
          OLD.revised_at, OLD.retain_until, OLD.erased_at)
      IS NOT DISTINCT FROM
      ROW(NEW.registration_answer_id, NEW.revision_number, NEW.revised_by_id,
          NEW.source, NEW.reason_code, NEW.idempotency_key_digest, NEW.request_digest,
          NEW.revised_at, NEW.retain_until, NEW.erased_at) THEN
    RETURN NEW;
  END IF;

  IF NEW.erased_at IS NOT NULL AND NEW.answer_ciphertext IS NULL AND
     ROW(OLD.registration_answer_id, OLD.revision_number, OLD.revised_by_id,
          OLD.source, OLD.reason_code, OLD.idempotency_key_digest, OLD.request_digest,
          OLD.revised_at, OLD.retain_until)
      IS NOT DISTINCT FROM
      ROW(NEW.registration_answer_id, NEW.revision_number, NEW.revised_by_id,
          NEW.source, NEW.reason_code, NEW.idempotency_key_digest, NEW.request_digest,
          NEW.revised_at, NEW.retain_until) THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'answer revisions are append-only except erasure'
    USING ERRCODE = '40001';
END;
$$;


--
-- Name: registration_answer_revision_delete_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.registration_answer_revision_delete_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'answer revisions cannot be deleted'
    USING ERRCODE = '40001';
END;
$$;


--
-- Name: registration_answer_revision_sequence(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.registration_answer_revision_sequence() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  expected_revision integer;
BEGIN
  SELECT COALESCE(MAX(revision_number), 0) + 1
    INTO expected_revision
    FROM ticketing_registration_answer_revisions
    WHERE registration_answer_id = NEW.registration_answer_id;
  IF NEW.revision_number <> expected_revision THEN
    RAISE EXCEPTION 'answer revisions must be appended in order'
      USING ERRCODE = '40001';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: registration_form_version_delete_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.registration_form_version_delete_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.status = 'draft' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'published or retired registration form versions cannot be deleted'
    USING ERRCODE = '40001';
END;
$$;


--
-- Name: registration_form_version_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.registration_form_version_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.status = 'draft' THEN
    RETURN NEW;
  END IF;

  IF OLD.status = 'published' AND NEW.status = 'retired' THEN
    IF ROW(OLD.registration_form_id, OLD.version, OLD.published_by_id, OLD.published_at)
       IS DISTINCT FROM
       ROW(NEW.registration_form_id, NEW.version, NEW.published_by_id, NEW.published_at) THEN
      RAISE EXCEPTION 'published registration form versions are immutable'
        USING ERRCODE = '40001';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status <> OLD.status OR
     ROW(OLD.registration_form_id, OLD.version, OLD.published_by_id, OLD.published_at)
     IS DISTINCT FROM
     ROW(NEW.registration_form_id, NEW.version, NEW.published_by_id, NEW.published_at) THEN
    RAISE EXCEPTION 'published or retired registration form versions are immutable'
      USING ERRCODE = '40001';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: registration_question_delete_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.registration_question_delete_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  version_status text;
BEGIN
  SELECT status INTO version_status
    FROM ticketing_registration_form_versions
    WHERE id = OLD.registration_form_version_id
    FOR UPDATE;
  IF version_status = 'draft' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'questions in published or retired versions cannot be deleted'
    USING ERRCODE = '40001';
END;
$$;


--
-- Name: registration_question_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.registration_question_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  version_status text;
  new_version_status text;
BEGIN
  SELECT status INTO version_status
    FROM ticketing_registration_form_versions
    WHERE id = OLD.registration_form_version_id
    FOR UPDATE;
  SELECT status INTO new_version_status
    FROM ticketing_registration_form_versions
    WHERE id = NEW.registration_form_version_id
    FOR UPDATE;
  IF COALESCE(version_status, '') <> 'draft' THEN
    RAISE EXCEPTION 'questions in published or retired versions are immutable'
      USING ERRCODE = '40001';
  END IF;
  IF COALESCE(new_version_status, '') <> 'draft' THEN
    RAISE EXCEPTION 'questions cannot move into published or retired versions'
      USING ERRCODE = '40001';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: registration_question_insert_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.registration_question_insert_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  version_status text;
BEGIN
  SELECT status INTO version_status
    FROM ticketing_registration_form_versions
    WHERE id = NEW.registration_form_version_id
    FOR UPDATE;
  IF version_status = 'draft' THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'questions cannot be added to published or retired versions'
    USING ERRCODE = '40001';
END;
$$;


--
-- Name: registration_source_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.registration_source_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.submitted_at IS NOT NULL AND NEW.source IS DISTINCT FROM OLD.source THEN
    RAISE EXCEPTION 'registration source is immutable after submission'
      USING ERRCODE = '40001';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: ticketing_admission_slot_shape_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_admission_slot_shape_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  expected_admission_count integer;
BEGIN
  SELECT admissions_per_unit_snapshot
    INTO expected_admission_count
    FROM ticketing_tickets
   WHERE id = NEW.ticket_id;

  IF NEW.position > expected_admission_count THEN
    RAISE EXCEPTION 'admission slot position exceeds the package snapshot'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: ticketing_admission_use_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_admission_use_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'ticketing_admission_uses_append_only' USING ERRCODE = '40001';
END;
$$;


--
-- Name: ticketing_admission_use_integrity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_admission_use_integrity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  slot_ticket_id uuid;
  credential_ticket_id uuid;
  checkin_ticket_id uuid;
  checkin_product_access_id uuid;
  checkin_event_date_id uuid;
  product_access_event_date_id uuid;
  checkin_result text;
BEGIN
  SELECT ticket_id INTO slot_ticket_id
  FROM ticketing_admission_slots WHERE id = NEW.admission_slot_id;

  SELECT ticket_id INTO credential_ticket_id
  FROM ticketing_credentials WHERE id = NEW.credential_id;

  SELECT ticket_id, product_access_id, event_date_id, result
    INTO checkin_ticket_id, checkin_product_access_id, checkin_event_date_id, checkin_result
  FROM ticketing_checkin_logs WHERE id = NEW.checkin_log_id;

  SELECT event_date_id INTO product_access_event_date_id
  FROM catalog_product_accesses WHERE id = NEW.product_access_id;

  IF checkin_result IS DISTINCT FROM 'success' OR
     slot_ticket_id IS DISTINCT FROM credential_ticket_id OR
     slot_ticket_id IS DISTINCT FROM checkin_ticket_id OR
     NEW.product_access_id IS DISTINCT FROM checkin_product_access_id OR
     checkin_event_date_id IS DISTINCT FROM product_access_event_date_id THEN
    RAISE EXCEPTION 'ticketing_admission_use_scope' USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: ticketing_admission_use_reversal_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_admission_use_reversal_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'ticketing_admission_use_reversals_append_only' USING ERRCODE = '40001';
END;
$$;


--
-- Name: ticketing_admission_use_reversal_integrity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_admission_use_reversal_integrity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  checkin_result text;
  checkin_event_id uuid;
  checkin_ticket_id uuid;
  checkin_use_count bigint;
  group_reversal_count bigint;
BEGIN
  SELECT result, ticket_id INTO checkin_result, checkin_ticket_id
  FROM ticketing_checkin_logs WHERE id = NEW.checkin_log_id;

  SELECT event_id INTO checkin_event_id
  FROM ticketing_tickets WHERE id = checkin_ticket_id;

  IF checkin_result IS DISTINCT FROM 'success' OR
     checkin_event_id IS DISTINCT FROM NEW.event_id THEN
    RAISE EXCEPTION 'ticketing_admission_use_reversal_checkin_scope'
      USING ERRCODE = '23514';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM ticketing_admission_use_reversals existing
    WHERE existing.reversal_group_id = NEW.reversal_group_id
      AND (existing.event_id IS DISTINCT FROM NEW.event_id OR
           existing.checkin_log_id IS DISTINCT FROM NEW.checkin_log_id)
  ) THEN
    RAISE EXCEPTION 'ticketing_admission_use_reversal_group_scope'
      USING ERRCODE = '23514';
  END IF;

  SELECT count(*) INTO checkin_use_count
  FROM ticketing_admission_uses
  WHERE checkin_log_id = NEW.checkin_log_id;

  SELECT count(*) INTO group_reversal_count
  FROM ticketing_admission_use_reversals
  WHERE reversal_group_id = NEW.reversal_group_id;

  IF checkin_use_count <> group_reversal_count OR EXISTS (
    SELECT 1
    FROM ticketing_admission_uses admission_use
    WHERE admission_use.checkin_log_id = NEW.checkin_log_id
      AND NOT EXISTS (
        SELECT 1
        FROM ticketing_admission_use_reversals reversal
        WHERE reversal.admission_use_id = admission_use.id
          AND reversal.reversal_group_id = NEW.reversal_group_id
      )
  ) THEN
    RAISE EXCEPTION 'ticketing_admission_use_reversal_incomplete_group'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: ticketing_checkin_log_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_checkin_log_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'ticketing_checkin_logs_append_only' USING ERRCODE = '40001';
END;
$$;


--
-- Name: ticketing_checkin_log_scope(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_checkin_log_scope() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  ticket_event_id uuid;
  product_access_event_id uuid;
  product_access_event_date_id uuid;
  event_date_event_id uuid;
  credential_ticket_id uuid;
  assignment_event_id uuid;
  upload_assignment_id uuid;
  zone_event_id uuid;
  zone_event_date_id uuid;
  override_result text;
  override_ticket_id uuid;
BEGIN
  SELECT event_id INTO ticket_event_id
  FROM ticketing_tickets WHERE id = NEW.ticket_id;

  SELECT product.event_id, access.event_date_id
    INTO product_access_event_id, product_access_event_date_id
  FROM catalog_product_accesses access
  JOIN catalog_event_products product
    ON product.id = access.event_product_id
  WHERE access.id = NEW.product_access_id;

  SELECT event_id INTO event_date_event_id
  FROM events_event_dates WHERE id = NEW.event_date_id;

  SELECT ticket_id INTO credential_ticket_id
  FROM ticketing_credentials WHERE id = NEW.credential_id;

  IF ticket_event_id IS DISTINCT FROM product_access_event_id OR
     ticket_event_id IS DISTINCT FROM event_date_event_id OR
     product_access_event_date_id IS DISTINCT FROM NEW.event_date_id OR
     credential_ticket_id IS DISTINCT FROM NEW.ticket_id THEN
    RAISE EXCEPTION 'ticketing_checkin_log_event_scope' USING ERRCODE = '23514';
  END IF;

  IF NEW.scanner_device_assignment_id IS NOT NULL THEN
    SELECT event_id INTO assignment_event_id
    FROM ticketing_scanner_device_assignments
    WHERE id = NEW.scanner_device_assignment_id;
    IF assignment_event_id IS DISTINCT FROM ticket_event_id THEN
      RAISE EXCEPTION 'ticketing_checkin_log_assignment_scope' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.scan_upload_id IS NOT NULL THEN
    SELECT scanner_device_assignment_id INTO upload_assignment_id
    FROM ticketing_scan_uploads WHERE id = NEW.scan_upload_id;
    IF upload_assignment_id IS DISTINCT FROM NEW.scanner_device_assignment_id THEN
      RAISE EXCEPTION 'ticketing_checkin_log_upload_scope' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.access_zone_id IS NOT NULL THEN
    SELECT event_id, event_date_id INTO zone_event_id, zone_event_date_id
    FROM events_access_zones WHERE id = NEW.access_zone_id;
    IF zone_event_id IS DISTINCT FROM ticket_event_id OR
       (zone_event_date_id IS NOT NULL AND zone_event_date_id IS DISTINCT FROM NEW.event_date_id) THEN
      RAISE EXCEPTION 'ticketing_checkin_log_zone_scope' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.overrides_checkin_log_id IS NOT NULL THEN
    SELECT result, ticket_id INTO override_result, override_ticket_id
    FROM ticketing_checkin_logs WHERE id = NEW.overrides_checkin_log_id;
    IF override_result IS DISTINCT FROM 'identity_mismatch' OR
       override_ticket_id IS DISTINCT FROM NEW.ticket_id THEN
      RAISE EXCEPTION 'ticketing_checkin_log_override_scope' USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: ticketing_credential_generation_cardinality_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_credential_generation_cardinality_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  generation_id uuid;
  generation_mode text;
  generation_ticket_id uuid;
  expected_slot_count integer;
  package_count integer;
  individual_count integer;
  invalid_positions boolean;
BEGIN
  generation_id := COALESCE(NEW.credential_generation_id, OLD.credential_generation_id);

  SELECT mode, ticket_id
    INTO generation_mode, generation_ticket_id
    FROM ticketing_credential_generations
   WHERE id = generation_id;

  SELECT COUNT(*)
    INTO expected_slot_count
    FROM ticketing_admission_slots
   WHERE ticket_id = generation_ticket_id;

  IF expected_slot_count <> (
    SELECT admissions_per_unit_snapshot
      FROM ticketing_tickets
     WHERE id = generation_ticket_id
  ) OR EXISTS (
    SELECT 1
      FROM ticketing_admission_slots slot
     WHERE slot.ticket_id = generation_ticket_id
       AND slot.position NOT BETWEEN 1 AND (
         SELECT admissions_per_unit_snapshot
           FROM ticketing_tickets
          WHERE id = generation_ticket_id
       )
  ) THEN
    RAISE EXCEPTION 'package admission slots must match the package snapshot'
      USING ERRCODE = '23514';
  END IF;

  SELECT COUNT(*) FILTER (WHERE type = 'package'),
         COUNT(*) FILTER (WHERE type = 'individual')
    INTO package_count, individual_count
    FROM ticketing_credentials
   WHERE credential_generation_id = generation_id;

  IF generation_mode = 'group' THEN
    IF package_count <> 1 OR individual_count <> 0 THEN
      RAISE EXCEPTION 'group generations require one package credential only'
        USING ERRCODE = '23514';
    END IF;

    SELECT EXISTS (
      SELECT 1
        FROM ticketing_credentials credential
       WHERE credential.credential_generation_id = generation_id
         AND (cardinality(credential.slot_positions) <> expected_slot_count OR
              EXISTS (
                SELECT 1
                  FROM ticketing_admission_slots slot
                 WHERE slot.ticket_id = generation_ticket_id
                   AND NOT (slot.position = ANY (credential.slot_positions))
              ))
    )
      INTO invalid_positions;
    IF invalid_positions THEN
      RAISE EXCEPTION 'group credential must cover every admission slot'
        USING ERRCODE = '23514';
    END IF;
  ELSIF generation_mode = 'delegated' THEN
    IF package_count <> 0 OR individual_count <> expected_slot_count THEN
      RAISE EXCEPTION 'delegated generations require one individual credential per slot'
        USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
      SELECT 1
        FROM ticketing_admission_slots slot
       WHERE slot.ticket_id = generation_ticket_id
         AND NOT EXISTS (
           SELECT 1
             FROM ticketing_credentials credential
            WHERE credential.credential_generation_id = generation_id
              AND credential.type = 'individual'
              AND credential.admission_slot_id = slot.id
         )
    ) THEN
      RAISE EXCEPTION 'delegated generations must cover every admission slot'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NULL;
END;
$$;


--
-- Name: ticketing_credential_shape_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_credential_shape_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  generation_mode text;
  expected_ticket_id uuid;
  current_generation_id uuid;
  current_generation_status text;
  ticket_event_id uuid;
  duplicate_count integer;
  invalid_position_count integer;
BEGIN
  SELECT mode, ticket_id
    INTO generation_mode, expected_ticket_id
    FROM ticketing_credential_generations
   WHERE id = NEW.credential_generation_id;

  IF NEW.ticket_id IS DISTINCT FROM expected_ticket_id THEN
    RAISE EXCEPTION 'credential ticket and generation do not match'
      USING ERRCODE = '23514';
  END IF;

  SELECT event_id, current_credential_generation_id
    INTO ticket_event_id, current_generation_id
    FROM ticketing_tickets
   WHERE id = NEW.ticket_id;

  IF NEW.event_id IS DISTINCT FROM ticket_event_id THEN
    RAISE EXCEPTION 'credential event and ticket do not match'
      USING ERRCODE = '23514';
  END IF;

  SELECT status
    INTO current_generation_status
    FROM ticketing_credential_generations
   WHERE id = current_generation_id;

  IF NEW.status IN ('active', 'pending_claim', 'pending_requirements') AND
     (current_generation_id IS DISTINCT FROM NEW.credential_generation_id OR
      current_generation_status IS DISTINCT FROM 'active') THEN
    RAISE EXCEPTION 'usable credentials must belong to the ticket current active generation'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.type = 'package' AND generation_mode IS DISTINCT FROM 'group' THEN
    RAISE EXCEPTION 'package credentials require group generations'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.type = 'individual' AND generation_mode IS DISTINCT FROM 'delegated' THEN
    RAISE EXCEPTION 'individual credentials require delegated generations'
      USING ERRCODE = '23514';
  END IF;

  SELECT COUNT(*) - COUNT(DISTINCT position), COUNT(*) FILTER (WHERE position <= 0)
    INTO duplicate_count, invalid_position_count
    FROM unnest(NEW.slot_positions) AS positions(position);

  IF duplicate_count <> 0 OR invalid_position_count <> 0 THEN
    RAISE EXCEPTION 'credential slot positions must be positive and unique'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.type = 'individual' AND cardinality(NEW.slot_positions) <> 1 THEN
    RAISE EXCEPTION 'individual credentials must contain one slot position'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.admission_slot_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
      FROM ticketing_admission_slots slot
     WHERE slot.id = NEW.admission_slot_id
       AND slot.ticket_id = NEW.ticket_id
       AND slot.position = NEW.slot_positions[1]
  ) THEN
    RAISE EXCEPTION 'credential admission slot does not match ticket position'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: ticketing_registration_answer_integrity_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_registration_answer_integrity_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  question_version_id uuid;
  question_key text;
  question_type text;
  question_scope text;
  question_label text;
  submission_version_id uuid;
  package_quantity integer;
  admissions_per_unit integer;
  retention_days integer;
  policy_category text;
  policy_status text;
  policy_effective_at timestamptz;
BEGIN
  SELECT question.registration_form_version_id, question.key, question.type,
         question.response_scope, question.label,
         submission.registration_form_version_id,
         registration.package_quantity, registration.admissions_per_unit_snapshot
    INTO question_version_id, question_key, question_type, question_scope, question_label,
         submission_version_id, package_quantity, admissions_per_unit
    FROM ticketing_registration_questions question
    JOIN ticketing_registration_form_submissions submission
      ON submission.id = NEW.registration_form_submission_id
    JOIN ticketing_registrations registration
      ON registration.id = submission.registration_id
   WHERE question.id = NEW.registration_question_id;

  IF question_version_id IS NULL OR question_version_id IS DISTINCT FROM submission_version_id OR
     NEW.question_key_snapshot IS DISTINCT FROM question_key OR
     NEW.question_type_snapshot IS DISTINCT FROM question_type OR
     NEW.response_scope_snapshot IS DISTINCT FROM question_scope OR
     NEW.question_label_snapshot IS DISTINCT FROM question_label THEN
    RAISE EXCEPTION 'registration answers must match their submission question and version'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.response_scope_snapshot = 'registration' THEN
    IF NEW.package_unit_number IS NOT NULL OR NEW.admission_position IS NOT NULL OR
       NEW.admission_slot_id IS NOT NULL THEN
      RAISE EXCEPTION 'registration-scoped answers cannot have admission coordinates'
        USING ERRCODE = '23514';
    END IF;
  ELSIF NEW.response_scope_snapshot = 'admission_slot' THEN
    IF NEW.package_unit_number IS NULL OR NEW.package_unit_number <= 0 OR
       NEW.package_unit_number > package_quantity OR
       NEW.admission_position IS NULL OR NEW.admission_position <= 0 OR
       NEW.admission_position > admissions_per_unit THEN
      RAISE EXCEPTION 'admission-slot answer coordinates are outside the registration bounds'
        USING ERRCODE = '23514';
    END IF;
  ELSE
    RAISE EXCEPTION 'registration answer response scope is invalid'
      USING ERRCODE = '23514';
  END IF;

  SELECT policy.retention_days, policy.category, policy.status, policy.effective_at
    INTO retention_days, policy_category, policy_status, policy_effective_at
    FROM core_data_retention_policies policy
   WHERE policy.id = NEW.retention_policy_id;
  IF policy_status IS DISTINCT FROM 'active' OR
     policy_effective_at IS NULL OR policy_effective_at > NEW.answered_at OR
     policy_category IS DISTINCT FROM (CASE
       WHEN question_type IN ('short_text', 'long_text') THEN 'registration_free_text'
       ELSE 'registration_structured'
     END) THEN
    RAISE EXCEPTION 'registration answers must use an active matching retention policy'
      USING ERRCODE = '23514';
  END IF;
  IF retention_days IS NULL AND NEW.retain_until IS NOT NULL THEN
    RAISE EXCEPTION 'answers with indefinite retention cannot have a deadline'
      USING ERRCODE = '23514';
  ELSIF retention_days IS NOT NULL AND
        NEW.retain_until IS DISTINCT FROM NEW.answered_at + retention_days * interval '1 day' THEN
    RAISE EXCEPTION 'registration answer retention deadlines must match the policy'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: ticketing_registration_answer_revision_retention_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_registration_answer_revision_retention_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  answer_retain_until timestamptz;
BEGIN
  SELECT retain_until INTO answer_retain_until
    FROM ticketing_registration_answers
   WHERE id = NEW.registration_answer_id;
  IF NEW.retain_until IS DISTINCT FROM answer_retain_until THEN
    RAISE EXCEPTION 'answer revisions must inherit the original retention deadline'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: ticketing_registration_consent_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_registration_consent_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'registration consent evidence is immutable and append-only'
    USING ERRCODE = '40001';
END;
$$;


--
-- Name: ticketing_registration_consent_integrity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_registration_consent_integrity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  requirement_registration_id uuid;
  requirement_scope text;
  requirement_subject_id uuid;
  requirement_status text;
  requirement_version_id uuid;
  version_digest text;
  registration_user_id uuid;
BEGIN
  SELECT requirement.registration_id, requirement.acceptance_scope,
         requirement.subject_user_id, requirement.status,
         requirement.consent_document_version_id,
         registration.user_id
    INTO requirement_registration_id, requirement_scope, requirement_subject_id,
         requirement_status, requirement_version_id, registration_user_id
    FROM ticketing_registration_consent_requirements requirement
    JOIN ticketing_registrations registration ON registration.id = requirement.registration_id
   WHERE requirement.id = NEW.registration_consent_requirement_id;
  SELECT content_sha256 INTO version_digest
    FROM events_consent_document_versions
   WHERE id = requirement_version_id;

  IF requirement_registration_id IS DISTINCT FROM NEW.registration_id OR
     requirement_status IS DISTINCT FROM 'pending' OR
     version_digest IS DISTINCT FROM NEW.content_sha256 THEN
    RAISE EXCEPTION 'consent evidence must match one pending exact-version requirement'
      USING ERRCODE = '23514';
  END IF;
  IF (requirement_scope = 'buyer' AND
      (NEW.signer_role IS DISTINCT FROM 'buyer' OR
       NEW.accepted_by_user_id IS DISTINCT FROM registration_user_id OR
       requirement_subject_id IS DISTINCT FROM registration_user_id)) OR
     (requirement_scope = 'admission_slot' AND
      (NEW.signer_role IS DISTINCT FROM 'attendee' OR
       requirement_subject_id IS DISTINCT FROM NEW.accepted_by_user_id)) THEN
    RAISE EXCEPTION 'consent evidence signer does not match the requirement subject'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: ticketing_registration_consent_requirement_acceptance_evidence(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_registration_consent_requirement_acceptance_evidence() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.status = 'accepted' AND NOT EXISTS (
    SELECT 1
      FROM ticketing_registration_consents consent
     WHERE consent.registration_consent_requirement_id = NEW.id
  ) THEN
    RAISE EXCEPTION 'accepted consent requirements require acceptance evidence'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: ticketing_registration_consent_requirement_integrity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_registration_consent_requirement_integrity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  registration_event_id uuid;
  registration_ticket_type_id uuid;
  document_event_id uuid;
  document_active boolean;
  version_status text;
  version_scope text;
  version_required boolean;
  ticket_event_id uuid;
BEGIN
  IF TG_OP = 'INSERT' AND NEW.status IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'new consent requirements must start pending'
      USING ERRCODE = '23514';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.registration_id IS DISTINCT FROM OLD.registration_id OR
       NEW.consent_document_version_id IS DISTINCT FROM OLD.consent_document_version_id OR
       NEW.required IS DISTINCT FROM OLD.required OR
       NEW.acceptance_scope IS DISTINCT FROM OLD.acceptance_scope OR
       NEW.package_unit_number IS DISTINCT FROM OLD.package_unit_number OR
       NEW.admission_position IS DISTINCT FROM OLD.admission_position OR
       NEW.admission_slot_id IS DISTINCT FROM OLD.admission_slot_id OR
       NEW.required_reason IS DISTINCT FROM OLD.required_reason OR
       NEW.required_by_id IS DISTINCT FROM OLD.required_by_id OR
       NEW.required_at IS DISTINCT FROM OLD.required_at OR
       NEW.supersedes_requirement_id IS DISTINCT FROM OLD.supersedes_requirement_id THEN
      RAISE EXCEPTION 'consent requirement snapshots and lineage are immutable'
        USING ERRCODE = '23514';
    END IF;

    IF NEW.subject_user_id IS DISTINCT FROM OLD.subject_user_id AND OLD.status <> 'pending' THEN
      RAISE EXCEPTION 'consent requirement subjects are immutable after acceptance begins'
        USING ERRCODE = '23514';
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
      (OLD.status = 'pending' AND NEW.status IN ('pending','accepted','withdrawn','superseded')) OR
      (OLD.status = 'accepted' AND NEW.status IN ('accepted','withdrawn','superseded')) OR
      (OLD.status = 'withdrawn' AND NEW.status = 'withdrawn') OR
      (OLD.status = 'superseded' AND NEW.status = 'superseded')
    ) THEN
      RAISE EXCEPTION 'invalid consent requirement status transition'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  SELECT registration.event_id, registration.ticket_type_id
    INTO registration_event_id, registration_ticket_type_id
    FROM ticketing_registrations registration
   WHERE registration.id = NEW.registration_id;

  SELECT document.event_id, document.active, version.status,
         version.acceptance_scope, version.required
    INTO document_event_id, document_active, version_status,
         version_scope, version_required
    FROM events_consent_document_versions version
    JOIN events_consent_documents document
      ON document.id = version.consent_document_id
   WHERE version.id = NEW.consent_document_version_id;

  IF registration_event_id IS DISTINCT FROM document_event_id THEN
    RAISE EXCEPTION 'consent requirements must reference one event'
      USING ERRCODE = '23514';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF document_active IS DISTINCT FROM TRUE OR version_status IS DISTINCT FROM 'published' OR EXISTS (
      SELECT 1
        FROM events_consent_document_versions newer_version
       WHERE newer_version.consent_document_id = (
         SELECT consent_document_id
           FROM events_consent_document_versions
          WHERE id = NEW.consent_document_version_id
       )
         AND newer_version.status = 'published'
         AND newer_version.id <> NEW.consent_document_version_id
    ) THEN
      RAISE EXCEPTION 'new consent requirements must use the current published active version'
        USING ERRCODE = '23514';
    END IF;
  ELSIF document_active IS DISTINCT FROM TRUE OR version_status IS NULL OR
        version_status NOT IN ('published','retired') THEN
    RAISE EXCEPTION 'existing consent requirements must retain a published or retired version'
      USING ERRCODE = '23514';
  END IF;
  IF version_scope IS DISTINCT FROM NEW.acceptance_scope OR
     version_required IS DISTINCT FROM NEW.required THEN
    RAISE EXCEPTION 'consent requirement snapshots must match the document version'
      USING ERRCODE = '23514';
  END IF;

  SELECT product.event_id
    INTO ticket_event_id
    FROM ticketing_ticket_types ticket_type
    JOIN catalog_event_products product ON product.id = ticket_type.event_product_id
   WHERE ticket_type.id = registration_ticket_type_id;
  IF ticket_event_id IS DISTINCT FROM registration_event_id THEN
    RAISE EXCEPTION 'consent requirements must use a ticket type from the registration event'
      USING ERRCODE = '23514';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM events_consent_document_products scoped_product
     WHERE scoped_product.consent_document_id = (
       SELECT consent_document_id
         FROM events_consent_document_versions
        WHERE id = NEW.consent_document_version_id
     )
  ) AND NOT EXISTS (
    SELECT 1
      FROM events_consent_document_products scoped_product
     WHERE scoped_product.consent_document_id = (
       SELECT consent_document_id
         FROM events_consent_document_versions
        WHERE id = NEW.consent_document_version_id
     )
       AND scoped_product.ticket_type_id = registration_ticket_type_id
  ) THEN
    RAISE EXCEPTION 'consent requirements must match the document ticket-product scope'
      USING ERRCODE = '23514';
  END IF;
  IF NEW.acceptance_scope = 'buyer' THEN
    IF NEW.subject_user_id IS DISTINCT FROM (
      SELECT user_id FROM ticketing_registrations WHERE id = NEW.registration_id
    ) THEN
      RAISE EXCEPTION 'buyer consent requirements must belong to the registration user'
        USING ERRCODE = '23514';
    END IF;
  ELSE
    IF NEW.package_unit_number > (
      SELECT package_quantity FROM ticketing_registrations WHERE id = NEW.registration_id
    ) OR NEW.admission_position > (
      SELECT admissions_per_unit_snapshot FROM ticketing_registrations WHERE id = NEW.registration_id
    ) THEN
      RAISE EXCEPTION 'consent requirement coordinates exceed the registration snapshot'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: ticketing_registration_consent_requirement_withdrawal_evidence(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_registration_consent_requirement_withdrawal_evidence() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.status = 'withdrawn' AND NOT EXISTS (
    SELECT 1
      FROM ticketing_registration_consents consent
      JOIN ticketing_registration_consent_withdrawals withdrawal
        ON withdrawal.registration_consent_id = consent.id
     WHERE consent.registration_consent_requirement_id = NEW.id
  ) THEN
    RAISE EXCEPTION 'withdrawn consent requirements require withdrawal evidence'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: ticketing_registration_consent_withdrawal_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_registration_consent_withdrawal_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'registration consent withdrawals are immutable and append-only'
    USING ERRCODE = '40001';
END;
$$;


--
-- Name: ticketing_registration_consent_withdrawal_integrity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_registration_consent_withdrawal_integrity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  consent_registration_id uuid;
  consent_signer_id uuid;
  requirement_scope text;
  requirement_status text;
BEGIN
  SELECT consent.registration_id, consent.accepted_by_user_id,
         requirement.acceptance_scope, requirement.status
    INTO consent_registration_id, consent_signer_id,
         requirement_scope, requirement_status
    FROM ticketing_registration_consents consent
    JOIN ticketing_registration_consent_requirements requirement
      ON requirement.id = consent.registration_consent_requirement_id
   WHERE consent.id = NEW.registration_consent_id;
  IF consent_registration_id IS DISTINCT FROM NEW.registration_id OR
     consent_signer_id IS DISTINCT FROM NEW.withdrawn_by_user_id OR
     requirement_scope IS DISTINCT FROM 'admission_slot' OR
     requirement_status IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'consent withdrawal must target the original signer''s accepted personal consent'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: ticketing_registration_form_scope_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_registration_form_scope_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  ticket_event_id uuid;
BEGIN
  IF TG_OP = 'UPDATE' AND
     (NEW.event_id IS DISTINCT FROM OLD.event_id OR
      NEW.ticket_type_id IS DISTINCT FROM OLD.ticket_type_id) AND
     EXISTS (
       SELECT 1
         FROM ticketing_registration_form_versions
        WHERE registration_form_id = OLD.id
          AND status <> 'draft'
     ) THEN
    RAISE EXCEPTION 'published registration form scopes are immutable'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.ticket_type_id IS NOT NULL THEN
    SELECT event_product.event_id INTO ticket_event_id
      FROM ticketing_ticket_types ticket_type
      JOIN catalog_event_products event_product ON event_product.id = ticket_type.event_product_id
      WHERE ticket_type.id = NEW.ticket_type_id;
    IF ticket_event_id IS DISTINCT FROM NEW.event_id THEN
      RAISE EXCEPTION 'registration forms must reference a ticket type from the same event'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: ticketing_registration_same_event_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_registration_same_event_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  ticket_event_id uuid;
  related_event_id uuid;
BEGIN
  IF TG_OP = 'UPDATE' AND
     (NEW.event_id IS DISTINCT FROM OLD.event_id OR
      NEW.ticket_type_id IS DISTINCT FROM OLD.ticket_type_id OR
      NEW.selected_event_date_id IS DISTINCT FROM OLD.selected_event_date_id OR
      NEW.package_quantity IS DISTINCT FROM OLD.package_quantity OR
      NEW.admissions_per_unit_snapshot IS DISTINCT FROM OLD.admissions_per_unit_snapshot OR
      NEW.party_size IS DISTINCT FROM OLD.party_size) AND
     EXISTS (
       SELECT 1
         FROM ticketing_registration_form_submissions
        WHERE registration_id = OLD.id
     ) THEN
     RAISE EXCEPTION 'registration scopes and snapshots are immutable after form submission'
       USING ERRCODE = '23514';
  END IF;

  SELECT event_product.event_id INTO ticket_event_id
    FROM ticketing_ticket_types ticket_type
    JOIN catalog_event_products event_product ON event_product.id = ticket_type.event_product_id
    WHERE ticket_type.id = NEW.ticket_type_id;
  IF ticket_event_id IS DISTINCT FROM NEW.event_id THEN
    RAISE EXCEPTION 'registrations must reference a ticket type from the same event'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.selected_event_date_id IS NOT NULL THEN
    SELECT event_id INTO related_event_id
      FROM events_event_dates
      WHERE id = NEW.selected_event_date_id;
    IF related_event_id IS DISTINCT FROM NEW.event_id THEN
      RAISE EXCEPTION 'registrations must reference an event date from the same event'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.access_code_id IS NOT NULL THEN
    SELECT event_product.event_id INTO related_event_id
      FROM ticketing_access_codes access_code
      JOIN ticketing_ticket_types ticket_type ON ticket_type.id = access_code.ticket_type_id
      JOIN catalog_event_products event_product ON event_product.id = ticket_type.event_product_id
      WHERE access_code.id = NEW.access_code_id;
    IF related_event_id IS DISTINCT FROM NEW.event_id THEN
      RAISE EXCEPTION 'registrations must reference an access code from the same event'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.invitation_id IS NOT NULL THEN
    SELECT event_product.event_id INTO related_event_id
      FROM ticketing_invitations invitation
      JOIN ticketing_ticket_types ticket_type ON ticket_type.id = invitation.ticket_type_id
      JOIN catalog_event_products event_product ON event_product.id = ticket_type.event_product_id
      WHERE invitation.id = NEW.invitation_id;
    IF related_event_id IS DISTINCT FROM NEW.event_id THEN
      RAISE EXCEPTION 'registrations must reference an invitation from the same event'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: ticketing_registration_submission_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_registration_submission_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'registration form submissions are immutable'
    USING ERRCODE = '40001';
END;
$$;


--
-- Name: ticketing_registration_submission_scope_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_registration_submission_scope_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  registration_event_id uuid;
  registration_ticket_type_id uuid;
  form_event_id uuid;
  form_ticket_type_id uuid;
BEGIN
  SELECT registration.event_id, registration.ticket_type_id,
         form.event_id, form.ticket_type_id
    INTO registration_event_id, registration_ticket_type_id,
         form_event_id, form_ticket_type_id
    FROM ticketing_registrations registration
    JOIN ticketing_registration_form_versions version
      ON version.id = NEW.registration_form_version_id
    JOIN ticketing_registration_forms form
      ON form.id = version.registration_form_id
   WHERE registration.id = NEW.registration_id;

  IF registration_event_id IS DISTINCT FROM form_event_id OR
     (form_ticket_type_id IS NOT NULL AND
      form_ticket_type_id IS DISTINCT FROM registration_ticket_type_id) THEN
    RAISE EXCEPTION 'registration submissions must reference a form from the same event and product scope'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: ticketing_scanner_assignment_zone_scope(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_scanner_assignment_zone_scope() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  assignment_event_id uuid;
  zone_event_id uuid;
BEGIN
  SELECT event_id INTO assignment_event_id
  FROM ticketing_scanner_device_assignments
  WHERE id = NEW.scanner_device_assignment_id;

  SELECT event_id INTO zone_event_id
  FROM events_access_zones
  WHERE id = NEW.access_zone_id;

  IF assignment_event_id IS DISTINCT FROM zone_event_id THEN
    RAISE EXCEPTION 'ticketing_scanner_assignment_zone_event_scope'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: ticketing_ticket_scope_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ticketing_ticket_scope_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  product_event_id uuid;
  product_type text;
  registration_event_id uuid;
  order_event_id uuid;
  acquisition_order_event_id uuid;
  generation_ticket_id uuid;
  generation_mode text;
  generation_version integer;
  generation_status text;
BEGIN
  SELECT event_id, type INTO product_event_id, product_type
    FROM catalog_event_products
   WHERE id = NEW.event_product_id;
  IF product_event_id IS DISTINCT FROM NEW.event_id OR product_type IS DISTINCT FROM 'ticket' THEN
    RAISE EXCEPTION 'ticket product and event do not match'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.registration_id IS NOT NULL THEN
    SELECT event_id INTO registration_event_id
      FROM ticketing_registrations
     WHERE id = NEW.registration_id;
    IF registration_event_id IS DISTINCT FROM NEW.event_id THEN
      RAISE EXCEPTION 'ticket registration and event do not match'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.order_item_id IS NOT NULL THEN
    SELECT order_record.event_id INTO order_event_id
      FROM orders_order_items item
      JOIN orders_orders order_record ON order_record.id = item.order_id
     WHERE item.id = NEW.order_item_id;
    IF order_event_id IS DISTINCT FROM NEW.event_id THEN
      RAISE EXCEPTION 'ticket order item and event do not match'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.current_acquisition_order_item_id IS NOT NULL THEN
    SELECT order_record.event_id INTO acquisition_order_event_id
      FROM orders_order_items item
      JOIN orders_orders order_record ON order_record.id = item.order_id
     WHERE item.id = NEW.current_acquisition_order_item_id;
    IF acquisition_order_event_id IS DISTINCT FROM NEW.event_id THEN
      RAISE EXCEPTION 'ticket acquisition order item and event do not match'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.current_credential_generation_id IS NOT NULL THEN
    SELECT ticket_id, mode, version, status
      INTO generation_ticket_id, generation_mode, generation_version, generation_status
      FROM ticketing_credential_generations
     WHERE id = NEW.current_credential_generation_id;
    IF generation_ticket_id IS DISTINCT FROM NEW.id OR
       generation_mode IS DISTINCT FROM NEW.credential_mode OR
       generation_version IS DISTINCT FROM NEW.credential_version OR
       generation_status IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'ticket current credential generation does not match the ticket'
        USING ERRCODE = '23514';
    END IF;
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
-- Name: commercial_approvals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_approvals (
    id uuid DEFAULT uuidv7() NOT NULL,
    target_type character varying NOT NULL,
    target_id uuid NOT NULL,
    decision character varying NOT NULL,
    reason text NOT NULL,
    definition_digest character varying(64) NOT NULL,
    actor_id uuid NOT NULL,
    decided_at timestamp with time zone NOT NULL,
    idempotency_key_digest character varying(64) NOT NULL,
    request_fingerprint character varying(64) NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT commercial_approvals_decision_check CHECK (((decision)::text = ANY ((ARRAY['approved'::character varying, 'rejected'::character varying])::text[]))),
    CONSTRAINT commercial_approvals_request_evidence_check CHECK ((((definition_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((idempotency_key_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((request_fingerprint)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT commercial_approvals_target_type_check CHECK (((target_type)::text = ANY ((ARRAY['Commercial::FeeScheduleVersion'::character varying, 'Commercial::Assignment'::character varying])::text[])))
);


--
-- Name: commercial_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_assignments (
    id uuid DEFAULT uuidv7() NOT NULL,
    organization_id uuid NOT NULL,
    event_id uuid,
    fee_schedule_version_id uuid NOT NULL,
    program_id uuid,
    assignment_type character varying NOT NULL,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    reason text NOT NULL,
    external_reference character varying,
    legal_acceptance_id uuid,
    effective_from timestamp with time zone NOT NULL,
    effective_until timestamp with time zone,
    risk_level character varying NOT NULL,
    created_by_id uuid NOT NULL,
    approved_by_id uuid,
    approved_at timestamp with time zone,
    activated_by_id uuid,
    activated_at timestamp with time zone,
    terminated_by_id uuid,
    terminated_at timestamp with time zone,
    external_accepted_by_id uuid,
    external_accepted_at timestamp with time zone,
    baseline_resolution_digest character varying(64),
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT commercial_assignments_active_metadata_check CHECK ((((status)::text <> 'active'::text) OR ((activated_by_id IS NOT NULL) AND (activated_at IS NOT NULL)))),
    CONSTRAINT commercial_assignments_assignment_type_check CHECK (((assignment_type)::text = ANY ((ARRAY['program'::character varying, 'platform_grant'::character varying, 'mutual_agreement'::character varying])::text[]))),
    CONSTRAINT commercial_assignments_baseline_digest_check CHECK (((baseline_resolution_digest IS NULL) OR ((baseline_resolution_digest)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT commercial_assignments_effective_interval_check CHECK (((effective_until IS NULL) OR (effective_until > effective_from))),
    CONSTRAINT commercial_assignments_external_acceptance_metadata_check CHECK (((external_reference IS NULL) OR ((external_accepted_by_id IS NOT NULL) AND (external_accepted_at IS NOT NULL)))),
    CONSTRAINT commercial_assignments_external_reference_check CHECK (((external_reference IS NULL) OR (NULLIF(btrim((external_reference)::text), ''::text) IS NOT NULL))),
    CONSTRAINT commercial_assignments_lock_version_check CHECK ((lock_version >= 0)),
    CONSTRAINT commercial_assignments_mutual_evidence_check CHECK ((((assignment_type)::text <> 'mutual_agreement'::text) OR ((status)::text <> ALL ((ARRAY['scheduled'::character varying, 'active'::character varying])::text[])) OR (legal_acceptance_id IS NOT NULL) OR (NULLIF(btrim((external_reference)::text), ''::text) IS NOT NULL))),
    CONSTRAINT commercial_assignments_platform_grant_baseline_check CHECK ((((assignment_type)::text <> 'platform_grant'::text) OR (baseline_resolution_digest IS NOT NULL))),
    CONSTRAINT commercial_assignments_risk_level_check CHECK (((risk_level)::text = ANY ((ARRAY['low'::character varying, 'medium'::character varying, 'high'::character varying])::text[]))),
    CONSTRAINT commercial_assignments_status_check CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'pending_acceptance'::character varying, 'pending_approval'::character varying, 'scheduled'::character varying, 'active'::character varying, 'expired'::character varying, 'terminated'::character varying])::text[]))),
    CONSTRAINT commercial_assignments_terminated_metadata_check CHECK ((((status)::text <> 'terminated'::text) OR ((terminated_by_id IS NOT NULL) AND (terminated_at IS NOT NULL))))
);


--
-- Name: commercial_event_payer_selections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_event_payer_selections (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    fee_component_id uuid NOT NULL,
    charged_to character varying NOT NULL,
    selected_by_id uuid,
    selected_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    idempotency_key_digest character varying(64) CONSTRAINT commercial_event_payer_selectio_idempotency_key_digest_not_null NOT NULL,
    request_fingerprint character varying(64) NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT commercial_event_payer_selections_payer_check CHECK (((charged_to)::text = ANY ((ARRAY['buyer'::character varying, 'organizer'::character varying])::text[]))),
    CONSTRAINT commercial_event_payer_selections_request_evidence_check CHECK ((((idempotency_key_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((request_fingerprint)::text ~ '^[0-9a-f]{64}$'::text)))
);


--
-- Name: commercial_fee_amounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_fee_amounts (
    id uuid DEFAULT uuidv7() NOT NULL,
    fee_component_id uuid NOT NULL,
    currency character varying(3) NOT NULL,
    fixed_amount_minor bigint,
    minimum_minor bigint,
    maximum_minor bigint,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT commercial_fee_amounts_currency_check CHECK (((currency)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT commercial_fee_amounts_fixed_amount_check CHECK (((fixed_amount_minor IS NULL) OR (fixed_amount_minor >= 0))),
    CONSTRAINT commercial_fee_amounts_maximum_check CHECK (((maximum_minor IS NULL) OR (maximum_minor >= 0))),
    CONSTRAINT commercial_fee_amounts_minimum_check CHECK (((minimum_minor IS NULL) OR (minimum_minor >= 0))),
    CONSTRAINT commercial_fee_amounts_ordered_bounds_check CHECK (((minimum_minor IS NULL) OR (maximum_minor IS NULL) OR (maximum_minor >= minimum_minor)))
);


--
-- Name: commercial_fee_components; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_fee_components (
    id uuid DEFAULT uuidv7() NOT NULL,
    fee_schedule_version_id uuid NOT NULL,
    component_type character varying NOT NULL,
    calculation_type character varying NOT NULL,
    charged_to character varying DEFAULT 'buyer'::character varying NOT NULL,
    organizer_payer_choice boolean DEFAULT false NOT NULL,
    funded_by character varying DEFAULT 'buyer'::character varying NOT NULL,
    basis_type character varying,
    rate_bps integer,
    refund_policy character varying DEFAULT 'nonrefundable'::character varying NOT NULL,
    offset_component_type character varying,
    event_product_id uuid,
    product_type character varying,
    sale_context character varying,
    provider character varying,
    payment_method character varying,
    sales_channel character varying,
    currency character varying(3),
    label character varying NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT commercial_fee_components_basis_shape_check CHECK (((((calculation_type)::text = ANY ((ARRAY['percentage'::character varying, 'blended'::character varying, 'tiered'::character varying])::text[])) AND (basis_type IS NOT NULL)) OR (((calculation_type)::text = ANY ((ARRAY['explicit_zero'::character varying, 'fixed'::character varying])::text[])) AND (basis_type IS NULL)))),
    CONSTRAINT commercial_fee_components_calculation_type_check CHECK (((calculation_type)::text = ANY ((ARRAY['explicit_zero'::character varying, 'percentage'::character varying, 'fixed'::character varying, 'blended'::character varying, 'tiered'::character varying])::text[]))),
    CONSTRAINT commercial_fee_components_charged_to_check CHECK (((charged_to)::text = ANY ((ARRAY['buyer'::character varying, 'organizer'::character varying])::text[]))),
    CONSTRAINT commercial_fee_components_component_type_check CHECK (((component_type)::text = ANY ((ARRAY['platform_commission'::character varying, 'buyer_service_fee'::character varying, 'processing_cost_recovery'::character varying, 'platform_subsidy'::character varying, 'resale_platform_fee'::character varying])::text[]))),
    CONSTRAINT commercial_fee_components_currency_check CHECK (((currency IS NULL) OR ((currency)::text ~ '^[A-Z]{3}$'::text))),
    CONSTRAINT commercial_fee_components_funded_by_check CHECK (((funded_by)::text = ANY ((ARRAY['buyer'::character varying, 'organizer'::character varying, 'platform'::character varying])::text[]))),
    CONSTRAINT commercial_fee_components_offset_type_check CHECK (((offset_component_type IS NULL) OR ((offset_component_type)::text = ANY ((ARRAY['platform_commission'::character varying, 'buyer_service_fee'::character varying, 'processing_cost_recovery'::character varying, 'resale_platform_fee'::character varying])::text[])))),
    CONSTRAINT commercial_fee_components_payment_method_check CHECK (((payment_method IS NULL) OR ((payment_method)::text = ANY ((ARRAY['telebirr'::character varying, 'card'::character varying, 'bank'::character varying])::text[])))),
    CONSTRAINT commercial_fee_components_product_type_check CHECK (((product_type IS NULL) OR ((product_type)::text = ANY ((ARRAY['ticket'::character varying, 'parking'::character varying, 'merchandise'::character varying, 'food'::character varying, 'donation'::character varying, 'digital_addon'::character varying, 'other'::character varying])::text[])))),
    CONSTRAINT commercial_fee_components_provider_check CHECK (((provider IS NULL) OR ((provider)::text = ANY ((ARRAY['chapa'::character varying, 'stripe'::character varying])::text[])))),
    CONSTRAINT commercial_fee_components_rate_check CHECK (((rate_bps IS NULL) OR ((rate_bps >= 0) AND (rate_bps <= 10000)))),
    CONSTRAINT commercial_fee_components_rate_shape_check CHECK (((((calculation_type)::text = ANY ((ARRAY['percentage'::character varying, 'blended'::character varying])::text[])) AND (rate_bps IS NOT NULL)) OR (((calculation_type)::text = ANY ((ARRAY['explicit_zero'::character varying, 'fixed'::character varying, 'tiered'::character varying])::text[])) AND (rate_bps IS NULL)))),
    CONSTRAINT commercial_fee_components_refund_policy_check CHECK (((refund_policy)::text = ANY ((ARRAY['refundable'::character varying, 'event_cancellation_only'::character varying, 'nonrefundable'::character varying])::text[]))),
    CONSTRAINT commercial_fee_components_sale_context_check CHECK (((sale_context IS NULL) OR ((sale_context)::text = ANY ((ARRAY['primary'::character varying, 'resale'::character varying])::text[])))),
    CONSTRAINT commercial_fee_components_sales_channel_check CHECK (((sales_channel IS NULL) OR ((sales_channel)::text = ANY ((ARRAY['online'::character varying, 'walk_up'::character varying, 'resale'::character varying])::text[])))),
    CONSTRAINT commercial_fee_components_subsidy_shape_check CHECK (((((component_type)::text = 'platform_subsidy'::text) AND ((funded_by)::text = 'platform'::text) AND (offset_component_type IS NOT NULL)) OR (((component_type)::text <> 'platform_subsidy'::text) AND ((funded_by)::text <> 'platform'::text) AND (offset_component_type IS NULL))))
);


--
-- Name: commercial_fee_schedule_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_fee_schedule_versions (
    id uuid DEFAULT uuidv7() NOT NULL,
    fee_schedule_id uuid NOT NULL,
    supersedes_version_id uuid,
    version integer NOT NULL,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    definition_digest character varying(64) NOT NULL,
    legal_document_version_id uuid,
    acceptance_policy character varying DEFAULT 'none'::character varying NOT NULL,
    grandfather_until timestamp with time zone,
    effective_from timestamp with time zone,
    effective_until timestamp with time zone,
    submitted_by_id uuid,
    submitted_at timestamp with time zone,
    approved_by_id uuid,
    approved_at timestamp with time zone,
    activated_by_id uuid,
    activated_at timestamp with time zone,
    terminated_by_id uuid,
    terminated_at timestamp with time zone,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT commercial_fee_schedule_versions_acceptance_policy_check CHECK (((acceptance_policy)::text = ANY ((ARRAY['none'::character varying, 'notice_only'::character varying, 'explicit'::character varying])::text[]))),
    CONSTRAINT commercial_fee_schedule_versions_authoritative_start_check CHECK ((((status)::text <> ALL ((ARRAY['scheduled'::character varying, 'active'::character varying])::text[])) OR (effective_from IS NOT NULL))),
    CONSTRAINT commercial_fee_schedule_versions_digest_check CHECK (((definition_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT commercial_fee_schedule_versions_effective_interval_check CHECK (((effective_until IS NULL) OR (effective_from IS NULL) OR (effective_until > effective_from))),
    CONSTRAINT commercial_fee_schedule_versions_lock_version_check CHECK ((lock_version >= 0)),
    CONSTRAINT commercial_fee_schedule_versions_status_check CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'simulated'::character varying, 'pending_approval'::character varying, 'approved'::character varying, 'scheduled'::character varying, 'active'::character varying, 'superseded'::character varying, 'expired'::character varying, 'terminated'::character varying])::text[]))),
    CONSTRAINT commercial_fee_schedule_versions_version_check CHECK ((version > 0))
);


--
-- Name: commercial_fee_schedules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_fee_schedules (
    id uuid DEFAULT uuidv7() NOT NULL,
    name character varying NOT NULL,
    code character varying NOT NULL,
    schedule_type character varying NOT NULL,
    created_by_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT commercial_fee_schedules_code_check CHECK (((code)::text ~ '^[a-z0-9]+(_[a-z0-9]+)*$'::text)),
    CONSTRAINT commercial_fee_schedules_schedule_type_check CHECK (((schedule_type)::text = ANY ((ARRAY['platform_default'::character varying, 'program'::character varying, 'custom'::character varying])::text[])))
);


--
-- Name: commercial_fee_tiers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_fee_tiers (
    id uuid DEFAULT uuidv7() NOT NULL,
    fee_component_id uuid NOT NULL,
    "position" integer NOT NULL,
    metric_type character varying NOT NULL,
    window_type character varying NOT NULL,
    currency character varying(3),
    starts_at_value bigint NOT NULL,
    rate_bps integer,
    fixed_amount_minor bigint,
    minimum_minor bigint,
    maximum_minor bigint,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT commercial_fee_tiers_currency_check CHECK (((currency IS NULL) OR ((currency)::text ~ '^[A-Z]{3}$'::text))),
    CONSTRAINT commercial_fee_tiers_fixed_amount_check CHECK (((fixed_amount_minor IS NULL) OR (fixed_amount_minor >= 0))),
    CONSTRAINT commercial_fee_tiers_gross_currency_check CHECK ((((metric_type)::text <> 'accepted_gross'::text) OR (currency IS NOT NULL))),
    CONSTRAINT commercial_fee_tiers_maximum_check CHECK (((maximum_minor IS NULL) OR (maximum_minor >= 0))),
    CONSTRAINT commercial_fee_tiers_metric_type_check CHECK (((metric_type)::text = ANY ((ARRAY['accepted_paid_units'::character varying, 'accepted_gross'::character varying])::text[]))),
    CONSTRAINT commercial_fee_tiers_minimum_check CHECK (((minimum_minor IS NULL) OR (minimum_minor >= 0))),
    CONSTRAINT commercial_fee_tiers_ordered_bounds_check CHECK (((minimum_minor IS NULL) OR (maximum_minor IS NULL) OR (maximum_minor >= minimum_minor))),
    CONSTRAINT commercial_fee_tiers_position_check CHECK (("position" > 0)),
    CONSTRAINT commercial_fee_tiers_rate_check CHECK (((rate_bps IS NULL) OR ((rate_bps >= 0) AND (rate_bps <= 10000)))),
    CONSTRAINT commercial_fee_tiers_threshold_check CHECK ((starts_at_value >= 0)),
    CONSTRAINT commercial_fee_tiers_window_type_check CHECK (((window_type)::text = ANY ((ARRAY['event'::character varying, 'calendar_month'::character varying, 'calendar_quarter'::character varying, 'calendar_year'::character varying, 'agreement_term'::character varying])::text[])))
);


--
-- Name: commercial_program_entitlements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_program_entitlements (
    id uuid DEFAULT uuidv7() NOT NULL,
    program_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    status character varying DEFAULT 'available'::character varying NOT NULL,
    reserved_event_id uuid,
    reserved_at timestamp with time zone,
    consumed_at timestamp with time zone,
    released_at timestamp with time zone,
    expires_at timestamp with time zone,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT commercial_program_entitlements_lock_version_check CHECK ((lock_version >= 0)),
    CONSTRAINT commercial_program_entitlements_state_check CHECK (((((status)::text = 'available'::text) AND (reserved_event_id IS NULL) AND (reserved_at IS NULL) AND (consumed_at IS NULL) AND (released_at IS NULL)) OR (((status)::text = 'reserved'::text) AND (reserved_event_id IS NOT NULL) AND (reserved_at IS NOT NULL) AND (consumed_at IS NULL) AND (released_at IS NULL)) OR (((status)::text = 'consumed'::text) AND (reserved_event_id IS NULL) AND (reserved_at IS NULL) AND (consumed_at IS NOT NULL) AND (released_at IS NULL)) OR (((status)::text = 'released'::text) AND (reserved_event_id IS NULL) AND (reserved_at IS NULL) AND (consumed_at IS NULL) AND (released_at IS NOT NULL)) OR (((status)::text = 'expired'::text) AND (reserved_event_id IS NULL) AND (reserved_at IS NULL) AND (consumed_at IS NULL) AND (released_at IS NULL) AND (expires_at IS NOT NULL)))),
    CONSTRAINT commercial_program_entitlements_status_check CHECK (((status)::text = ANY ((ARRAY['available'::character varying, 'reserved'::character varying, 'consumed'::character varying, 'released'::character varying, 'expired'::character varying])::text[])))
);


--
-- Name: commercial_programs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_programs (
    id uuid DEFAULT uuidv7() NOT NULL,
    fee_schedule_id uuid NOT NULL,
    program_type character varying NOT NULL,
    enrollment_mode character varying DEFAULT 'automatic'::character varying NOT NULL,
    starts_at timestamp with time zone,
    ends_at timestamp with time zone,
    per_organization_use_limit integer,
    active boolean DEFAULT false NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT commercial_programs_effective_interval_check CHECK (((ends_at IS NULL) OR (starts_at IS NULL) OR (ends_at > starts_at))),
    CONSTRAINT commercial_programs_enrollment_mode_check CHECK (((enrollment_mode)::text = ANY ((ARRAY['automatic'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT commercial_programs_program_type_check CHECK (((program_type)::text = ANY ((ARRAY['first_monetized_event'::character varying, 'charity'::character varying, 'partnership'::character varying, 'volume'::character varying])::text[]))),
    CONSTRAINT commercial_programs_use_limit_check CHECK (((per_organization_use_limit IS NULL) OR (per_organization_use_limit > 0)))
);


--
-- Name: commercial_simulations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_simulations (
    id uuid DEFAULT uuidv7() NOT NULL,
    fee_schedule_version_id uuid NOT NULL,
    assignment_id uuid,
    definition_digest character varying(64) NOT NULL,
    scenario_digest character varying(64) NOT NULL,
    normalized_outputs jsonb DEFAULT '{}'::jsonb NOT NULL,
    warnings jsonb DEFAULT '[]'::jsonb NOT NULL,
    passed boolean DEFAULT false NOT NULL,
    run_by_id uuid NOT NULL,
    run_at timestamp with time zone NOT NULL,
    idempotency_key_digest character varying(64) NOT NULL,
    request_fingerprint character varying(64) NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT commercial_simulations_digest_check CHECK ((((definition_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((scenario_digest)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT commercial_simulations_payload_shape_check CHECK (((jsonb_typeof(normalized_outputs) = 'object'::text) AND (jsonb_typeof(warnings) = 'array'::text))),
    CONSTRAINT commercial_simulations_request_evidence_check CHECK ((((idempotency_key_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((request_fingerprint)::text ~ '^[0-9a-f]{64}$'::text)))
);


--
-- Name: commercial_subsidy_budgets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_subsidy_budgets (
    id uuid DEFAULT uuidv7() NOT NULL,
    assignment_id uuid,
    program_id uuid,
    fee_component_id uuid NOT NULL,
    currency character varying(3) NOT NULL,
    limit_minor bigint NOT NULL,
    reserved_minor bigint DEFAULT 0 NOT NULL,
    consumed_minor bigint DEFAULT 0 NOT NULL,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT commercial_subsidy_budgets_consumed_check CHECK ((consumed_minor >= 0)),
    CONSTRAINT commercial_subsidy_budgets_counter_limit_check CHECK (((reserved_minor + consumed_minor) <= limit_minor)),
    CONSTRAINT commercial_subsidy_budgets_currency_check CHECK (((currency)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT commercial_subsidy_budgets_limit_check CHECK ((limit_minor > 0)),
    CONSTRAINT commercial_subsidy_budgets_lock_version_check CHECK ((lock_version >= 0)),
    CONSTRAINT commercial_subsidy_budgets_owner_check CHECK ((((assignment_id IS NOT NULL) AND (program_id IS NULL)) OR ((assignment_id IS NULL) AND (program_id IS NOT NULL)))),
    CONSTRAINT commercial_subsidy_budgets_reserved_check CHECK ((reserved_minor >= 0))
);


--
-- Name: commercial_subsidy_reservations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_subsidy_reservations (
    id uuid DEFAULT uuidv7() NOT NULL,
    subsidy_budget_id uuid NOT NULL,
    order_id uuid NOT NULL,
    idempotency_key_digest character varying(64) NOT NULL,
    request_fingerprint character varying(64) NOT NULL,
    amount_minor bigint NOT NULL,
    currency character varying(3) NOT NULL,
    status character varying DEFAULT 'held'::character varying NOT NULL,
    expires_at timestamp with time zone,
    committed_at timestamp with time zone,
    released_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT commercial_subsidy_reservations_amount_check CHECK ((amount_minor > 0)),
    CONSTRAINT commercial_subsidy_reservations_currency_check CHECK (((currency)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT commercial_subsidy_reservations_request_evidence_check CHECK ((((idempotency_key_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((request_fingerprint)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT commercial_subsidy_reservations_state_check CHECK (((((status)::text = ANY ((ARRAY['held'::character varying, 'processing'::character varying])::text[])) AND (expires_at IS NOT NULL) AND (committed_at IS NULL) AND (released_at IS NULL)) OR (((status)::text = 'committed'::text) AND (committed_at IS NOT NULL) AND (released_at IS NULL)) OR (((status)::text = 'released'::text) AND (released_at IS NOT NULL) AND (committed_at IS NULL)))),
    CONSTRAINT commercial_subsidy_reservations_status_check CHECK (((status)::text = ANY ((ARRAY['held'::character varying, 'processing'::character varying, 'committed'::character varying, 'released'::character varying])::text[])))
);


--
-- Name: commercial_term_notices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_term_notices (
    id uuid DEFAULT uuidv7() NOT NULL,
    organization_id uuid NOT NULL,
    fee_schedule_version_id uuid NOT NULL,
    legal_document_version_id uuid NOT NULL,
    delivery_method character varying DEFAULT 'in_app'::character varying NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    evidence_digest character varying(64) NOT NULL,
    available_at timestamp with time zone NOT NULL,
    delivered_at timestamp with time zone,
    failed_at timestamp with time zone,
    idempotency_key_digest character varying(64) NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT commercial_term_notices_delivery_method_check CHECK (((delivery_method)::text = 'in_app'::text)),
    CONSTRAINT commercial_term_notices_evidence_check CHECK ((((evidence_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((idempotency_key_digest)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT commercial_term_notices_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'delivered'::character varying, 'failed'::character varying])::text[]))),
    CONSTRAINT commercial_term_notices_status_metadata_check CHECK (((((status)::text = 'delivered'::text) AND (delivered_at IS NOT NULL) AND (failed_at IS NULL)) OR (((status)::text = 'failed'::text) AND (failed_at IS NOT NULL) AND (delivered_at IS NULL)) OR (((status)::text = 'pending'::text) AND (delivered_at IS NULL) AND (failed_at IS NULL))))
);


--
-- Name: commercial_volume_counters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_volume_counters (
    id uuid DEFAULT uuidv7() NOT NULL,
    fee_component_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    event_id uuid,
    metric_type character varying NOT NULL,
    window_type character varying NOT NULL,
    window_start_at timestamp with time zone NOT NULL,
    window_end_at timestamp with time zone,
    currency character varying(3),
    value bigint DEFAULT 0 NOT NULL,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT commercial_volume_counters_currency_check CHECK (((((metric_type)::text = 'accepted_gross'::text) AND (currency IS NOT NULL) AND ((currency)::text ~ '^[A-Z]{3}'::text)) OR (((metric_type)::text = 'accepted_paid_units'::text) AND (currency IS NULL)))),
    CONSTRAINT commercial_volume_counters_event_window_check CHECK ((((window_type)::text <> 'event'::text) OR (event_id IS NOT NULL))),
    CONSTRAINT commercial_volume_counters_metric_type_check CHECK (((metric_type)::text = ANY ((ARRAY['accepted_paid_units'::character varying, 'accepted_gross'::character varying])::text[]))),
    CONSTRAINT commercial_volume_counters_value_check CHECK (((value >= 0) AND (lock_version >= 0))),
    CONSTRAINT commercial_volume_counters_window_bounds_check CHECK (((window_end_at IS NULL) OR (window_end_at > window_start_at))),
    CONSTRAINT commercial_volume_counters_window_type_check CHECK (((window_type)::text = ANY ((ARRAY['event'::character varying, 'calendar_month'::character varying, 'calendar_quarter'::character varying, 'calendar_year'::character varying, 'agreement_term'::character varying])::text[])))
);


--
-- Name: commercial_volume_usages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_volume_usages (
    id uuid DEFAULT uuidv7() NOT NULL,
    fee_component_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    event_id uuid,
    order_id uuid NOT NULL,
    metric_type character varying NOT NULL,
    window_type character varying NOT NULL,
    window_start_at timestamp with time zone NOT NULL,
    window_end_at timestamp with time zone,
    currency character varying(3),
    value bigint NOT NULL,
    accepted_at timestamp with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT commercial_volume_usages_currency_check CHECK (((((metric_type)::text = 'accepted_gross'::text) AND (currency IS NOT NULL) AND ((currency)::text ~ '^[A-Z]{3}'::text)) OR (((metric_type)::text = 'accepted_paid_units'::text) AND (currency IS NULL)))),
    CONSTRAINT commercial_volume_usages_event_window_check CHECK ((((window_type)::text <> 'event'::text) OR (event_id IS NOT NULL))),
    CONSTRAINT commercial_volume_usages_metric_type_check CHECK (((metric_type)::text = ANY ((ARRAY['accepted_paid_units'::character varying, 'accepted_gross'::character varying])::text[]))),
    CONSTRAINT commercial_volume_usages_value_check CHECK ((value >= 0)),
    CONSTRAINT commercial_volume_usages_window_bounds_check CHECK (((window_end_at IS NULL) OR (window_end_at > window_start_at))),
    CONSTRAINT commercial_volume_usages_window_type_check CHECK (((window_type)::text = ANY ((ARRAY['event'::character varying, 'calendar_month'::character varying, 'calendar_quarter'::character varying, 'calendar_year'::character varying, 'agreement_term'::character varying])::text[])))
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
-- Name: core_data_retention_holds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_data_retention_holds (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid,
    registration_id uuid,
    user_id uuid,
    category character varying,
    reason_code character varying NOT NULL,
    placed_by_id uuid NOT NULL,
    starts_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone,
    released_by_id uuid,
    released_at timestamp with time zone,
    idempotency_key character varying NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT core_retention_holds_category_check CHECK (((category IS NULL) OR ((category)::text = ANY ((ARRAY['registration_free_text'::character varying, 'registration_structured'::character varying, 'consent_evidence'::character varying, 'security_audit'::character varying, 'financial_record'::character varying])::text[])))),
    CONSTRAINT core_retention_holds_one_scope_check CHECK ((num_nonnulls(event_id, registration_id, user_id) = 1)),
    CONSTRAINT core_retention_holds_reason_check CHECK (((reason_code)::text = ANY ((ARRAY['legal_hold'::character varying, 'litigation'::character varying, 'regulatory_investigation'::character varying, 'security_incident'::character varying, 'security_hold'::character varying, 'fraud_investigation'::character varying, 'law_enforcement_request'::character varying])::text[]))),
    CONSTRAINT core_retention_holds_release_pair_check CHECK ((((released_at IS NULL) AND (released_by_id IS NULL)) OR ((released_at IS NOT NULL) AND (released_by_id IS NOT NULL)))),
    CONSTRAINT core_retention_holds_release_time_check CHECK (((released_at IS NULL) OR (released_at >= starts_at))),
    CONSTRAINT core_retention_holds_window_check CHECK (((expires_at IS NULL) OR (expires_at > starts_at)))
);


--
-- Name: core_data_retention_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_data_retention_policies (
    id uuid DEFAULT uuidv7() NOT NULL,
    category character varying NOT NULL,
    jurisdiction_code character varying,
    version integer NOT NULL,
    retention_days integer,
    action character varying NOT NULL,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    effective_at timestamp with time zone,
    created_by_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT core_retention_policies_action_check CHECK (((action)::text = ANY ((ARRAY['erase_payload'::character varying, 'retain'::character varying])::text[]))),
    CONSTRAINT core_retention_policies_category_check CHECK (((category)::text = ANY ((ARRAY['registration_free_text'::character varying, 'registration_structured'::character varying, 'consent_evidence'::character varying, 'security_audit'::character varying, 'financial_record'::character varying])::text[]))),
    CONSTRAINT core_retention_policies_configuration_check CHECK (((((action)::text = 'retain'::text) OR (retention_days IS NOT NULL)) AND (((status)::text <> 'active'::text) OR (effective_at IS NOT NULL)))),
    CONSTRAINT core_retention_policies_days_check CHECK (((retention_days IS NULL) OR (retention_days > 0))),
    CONSTRAINT core_retention_policies_status_check CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'active'::character varying, 'retired'::character varying])::text[]))),
    CONSTRAINT core_retention_policies_version_check CHECK ((version > 0))
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
-- Name: core_reauthentication_proofs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_reauthentication_proofs (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    session_jti_digest character varying(64) NOT NULL,
    purpose character varying NOT NULL,
    factor_type character varying NOT NULL,
    token_digest character varying(64) NOT NULL,
    issued_at timestamp(6) with time zone NOT NULL,
    expires_at timestamp(6) with time zone NOT NULL,
    consumed_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT core_reauthentication_proofs_consumed_after_issue CHECK (((consumed_at IS NULL) OR (consumed_at >= issued_at))),
    CONSTRAINT core_reauthentication_proofs_digest_shape CHECK ((((session_jti_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((token_digest)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT core_reauthentication_proofs_exact_lifetime CHECK ((expires_at = (issued_at + '00:05:00'::interval))),
    CONSTRAINT core_reauthentication_proofs_factor_allowlist CHECK (((factor_type)::text = 'password'::text)),
    CONSTRAINT core_reauthentication_proofs_ordered_window CHECK ((expires_at >= issued_at)),
    CONSTRAINT core_reauthentication_proofs_purpose_allowlist CHECK (((purpose)::text = ANY ((ARRAY['attendee_export_request'::character varying, 'attendee_export_download'::character varying])::text[])))
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
    CONSTRAINT chk_legal_acceptance_subject_type CHECK (((subject_type)::text = ANY ((ARRAY['user'::character varying, 'organization'::character varying, 'order'::character varying, 'commercial_assignment'::character varying])::text[])))
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
-- Name: orders_order_adjustments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders_order_adjustments (
    id uuid DEFAULT uuidv7() NOT NULL,
    order_id uuid NOT NULL,
    order_item_id uuid,
    type character varying NOT NULL,
    label character varying NOT NULL,
    charged_to character varying NOT NULL,
    amount_minor bigint NOT NULL,
    currency character varying(3) NOT NULL,
    refund_policy character varying NOT NULL,
    calculation_type character varying,
    basis_type character varying,
    basis_minor bigint,
    rate_bps integer,
    fixed_amount_minor bigint,
    minimum_minor bigint,
    maximum_minor bigint,
    funded_by character varying,
    source_type character varying,
    source_id uuid,
    resolution_evidence jsonb,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT order_adjustment_source_pair CHECK (((source_type IS NULL) = (source_id IS NULL))),
    CONSTRAINT orders_adjustments_amount_sign_check CHECK (((((type)::text = ANY ((ARRAY['discount'::character varying, 'subsidy'::character varying])::text[])) AND (amount_minor < 0)) OR (((type)::text = ANY ((ARRAY['service_fee'::character varying, 'platform_fee'::character varying, 'processing_fee'::character varying, 'resale_platform_fee'::character varying, 'tax'::character varying])::text[])) AND (amount_minor >= 0)) OR ((type)::text = 'manual_adjustment'::text))),
    CONSTRAINT orders_adjustments_basis_amount_check CHECK (((basis_minor IS NULL) OR (basis_minor >= 0))),
    CONSTRAINT orders_adjustments_basis_amount_shape_check CHECK (((calculation_type IS NULL) OR ((calculation_type)::text <> ALL ((ARRAY['explicit_zero'::character varying, 'fixed'::character varying])::text[])) OR (basis_minor IS NULL))),
    CONSTRAINT orders_adjustments_basis_check CHECK (((basis_type IS NULL) OR ((basis_type)::text = ANY ((ARRAY['item_face_value'::character varying, 'item_net_value_after_organizer_promotion'::character varying, 'eligible_order_subtotal'::character varying, 'resale_acquisition_amount'::character varying, 'accepted_paid_units'::character varying, 'accepted_gross'::character varying])::text[])))),
    CONSTRAINT orders_adjustments_basis_shape_check CHECK (((((calculation_type)::text = ANY ((ARRAY['percentage'::character varying, 'blended'::character varying, 'tiered'::character varying])::text[])) AND (basis_type IS NOT NULL)) OR (((calculation_type)::text = ANY ((ARRAY['explicit_zero'::character varying, 'fixed'::character varying])::text[])) AND (basis_type IS NULL)) OR (calculation_type IS NULL))),
    CONSTRAINT orders_adjustments_bounds_check CHECK ((((fixed_amount_minor IS NULL) OR (fixed_amount_minor >= 0)) AND ((minimum_minor IS NULL) OR (minimum_minor >= 0)) AND ((maximum_minor IS NULL) OR (maximum_minor >= 0)) AND ((minimum_minor IS NULL) OR (maximum_minor IS NULL) OR (maximum_minor >= minimum_minor)))),
    CONSTRAINT orders_adjustments_calculation_check CHECK (((calculation_type IS NULL) OR ((calculation_type)::text = ANY ((ARRAY['explicit_zero'::character varying, 'percentage'::character varying, 'fixed'::character varying, 'blended'::character varying, 'tiered'::character varying])::text[])))),
    CONSTRAINT orders_adjustments_charged_to_check CHECK (((charged_to)::text = ANY ((ARRAY['buyer'::character varying, 'organizer'::character varying])::text[]))),
    CONSTRAINT orders_adjustments_commercial_shape_check CHECK ((((type)::text <> ALL ((ARRAY['service_fee'::character varying, 'platform_fee'::character varying, 'processing_fee'::character varying, 'subsidy'::character varying, 'resale_platform_fee'::character varying])::text[])) OR ((calculation_type IS NOT NULL) AND (funded_by IS NOT NULL) AND (source_type IS NOT NULL) AND (source_id IS NOT NULL)))),
    CONSTRAINT orders_adjustments_currency_check CHECK (((currency)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT orders_adjustments_evidence_check CHECK (public.orders_order_adjustment_evidence_valid(resolution_evidence)),
    CONSTRAINT orders_adjustments_explicit_zero_check CHECK ((((calculation_type)::text <> 'explicit_zero'::text) OR ((fixed_amount_minor IS NULL) AND (minimum_minor IS NULL) AND (maximum_minor IS NULL)))),
    CONSTRAINT orders_adjustments_fixed_shape_check CHECK ((((calculation_type)::text <> ALL ((ARRAY['fixed'::character varying, 'blended'::character varying])::text[])) OR (fixed_amount_minor IS NOT NULL) OR (calculation_type IS NULL))),
    CONSTRAINT orders_adjustments_funded_by_check CHECK (((funded_by IS NULL) OR ((funded_by)::text = ANY ((ARRAY['buyer'::character varying, 'organizer'::character varying, 'platform'::character varying])::text[])))),
    CONSTRAINT orders_adjustments_rate_check CHECK (((rate_bps IS NULL) OR ((rate_bps >= 0) AND (rate_bps <= 10000)))),
    CONSTRAINT orders_adjustments_rate_shape_check CHECK (((((calculation_type)::text = ANY ((ARRAY['percentage'::character varying, 'blended'::character varying])::text[])) AND (rate_bps IS NOT NULL)) OR (((calculation_type)::text = ANY ((ARRAY['explicit_zero'::character varying, 'fixed'::character varying, 'tiered'::character varying])::text[])) AND (rate_bps IS NULL)) OR (calculation_type IS NULL))),
    CONSTRAINT orders_adjustments_refund_policy_check CHECK (((refund_policy)::text = ANY ((ARRAY['refundable'::character varying, 'event_cancellation_only'::character varying, 'nonrefundable'::character varying])::text[]))),
    CONSTRAINT orders_adjustments_source_type_check CHECK (((source_type IS NULL) OR ((source_type)::text = ANY ((ARRAY['Catalog::Promotion'::character varying, 'Commercial::FeeComponent'::character varying])::text[])))),
    CONSTRAINT orders_adjustments_subsidy_shape_check CHECK (((((type)::text <> 'subsidy'::text) OR ((funded_by)::text = 'platform'::text)) AND ((funded_by IS NULL) OR ((type)::text = 'subsidy'::text) OR ((funded_by)::text <> 'platform'::text)))),
    CONSTRAINT orders_adjustments_type_check CHECK (((type)::text = ANY ((ARRAY['discount'::character varying, 'service_fee'::character varying, 'platform_fee'::character varying, 'processing_fee'::character varying, 'subsidy'::character varying, 'resale_platform_fee'::character varying, 'tax'::character varying, 'manual_adjustment'::character varying])::text[])))
);


--
-- Name: orders_order_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders_order_items (
    id uuid DEFAULT uuidv7() NOT NULL,
    order_id uuid NOT NULL,
    event_product_id uuid NOT NULL,
    registration_id uuid,
    resale_listing_id uuid,
    name_snapshot character varying NOT NULL,
    type_snapshot character varying NOT NULL,
    quantity integer NOT NULL,
    admissions_per_unit_snapshot smallint,
    base_currency character varying(3) NOT NULL,
    base_unit_amount_minor bigint NOT NULL,
    charge_currency character varying(3) NOT NULL,
    charge_unit_amount_minor bigint NOT NULL,
    exchange_rate numeric(24,12),
    discount_minor bigint DEFAULT 0 NOT NULL,
    total_minor bigint NOT NULL,
    fulfillment_status character varying DEFAULT 'pending'::character varying NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT order_item_quantity_positive CHECK ((quantity > 0)),
    CONSTRAINT orders_order_items_admissions_check CHECK (((((type_snapshot)::text = 'ticket'::text) AND (admissions_per_unit_snapshot > 0)) OR (((type_snapshot)::text <> 'ticket'::text) AND (admissions_per_unit_snapshot IS NULL)))),
    CONSTRAINT orders_order_items_amounts_check CHECK (((base_unit_amount_minor >= 0) AND (charge_unit_amount_minor >= 0) AND (discount_minor >= 0) AND (total_minor >= 0))),
    CONSTRAINT orders_order_items_currency_check CHECK ((((base_currency)::text ~ '^[A-Z]{3}$'::text) AND ((charge_currency)::text ~ '^[A-Z]{3}$'::text))),
    CONSTRAINT orders_order_items_exchange_check CHECK ((((base_currency)::text = (charge_currency)::text) OR ((exchange_rate IS NOT NULL) AND (exchange_rate > (0)::numeric)))),
    CONSTRAINT orders_order_items_fulfillment_check CHECK (((fulfillment_status)::text = ANY ((ARRAY['pending'::character varying, 'fulfilled'::character varying, 'cancelled'::character varying, 'refunded'::character varying])::text[]))),
    CONSTRAINT orders_order_items_type_check CHECK (((type_snapshot)::text = ANY ((ARRAY['ticket'::character varying, 'parking'::character varying, 'merchandise'::character varying, 'food'::character varying, 'donation'::character varying, 'digital_addon'::character varying, 'other'::character varying])::text[])))
);


--
-- Name: orders_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders_orders (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    buyer_user_id uuid NOT NULL,
    sales_channel character varying DEFAULT 'online'::character varying NOT NULL,
    initiated_by_id uuid,
    replaces_order_id uuid,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    closed_reason character varying,
    charge_currency character varying(3) NOT NULL,
    subtotal_minor bigint NOT NULL,
    discount_minor bigint DEFAULT 0 NOT NULL,
    subsidy_minor bigint DEFAULT 0 NOT NULL,
    fee_minor bigint DEFAULT 0 NOT NULL,
    tax_minor bigint DEFAULT 0 NOT NULL,
    adjustment_minor bigint DEFAULT 0 NOT NULL,
    total_minor bigint NOT NULL,
    settlement_currency character varying(3) NOT NULL,
    settlement_total_minor bigint NOT NULL,
    exchange_rate numeric(24,12) DEFAULT 1.0 NOT NULL,
    exchange_rate_source character varying NOT NULL,
    exchange_rate_quoted_at timestamp with time zone,
    exchange_rate_expires_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL,
    paid_at timestamp with time zone,
    lock_version integer DEFAULT 0 NOT NULL,
    idempotency_key_digest character varying(64) NOT NULL,
    creation_request_digest character varying(64) NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT orders_orders_amounts_check CHECK (((subtotal_minor >= 0) AND (discount_minor >= 0) AND (subsidy_minor >= 0) AND (fee_minor >= 0) AND (tax_minor >= 0) AND (settlement_total_minor >= 0))),
    CONSTRAINT orders_orders_closed_reason_check CHECK (((((status)::text = ANY ((ARRAY['expired'::character varying, 'cancelled'::character varying])::text[])) AND (closed_reason IS NOT NULL)) OR (((status)::text <> ALL ((ARRAY['expired'::character varying, 'cancelled'::character varying])::text[])) AND (closed_reason IS NULL)))),
    CONSTRAINT orders_orders_creation_digests_check CHECK ((((idempotency_key_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((creation_request_digest)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT orders_orders_currency_check CHECK ((((charge_currency)::text ~ '^[A-Z]{3}$'::text) AND ((settlement_currency)::text ~ '^[A-Z]{3}$'::text))),
    CONSTRAINT orders_orders_exchange_metadata_check CHECK (((((charge_currency)::text = (settlement_currency)::text) AND (exchange_rate = (1)::numeric)) OR (((charge_currency)::text <> (settlement_currency)::text) AND (exchange_rate_quoted_at IS NOT NULL) AND (exchange_rate_expires_at IS NOT NULL) AND (exchange_rate_expires_at > exchange_rate_quoted_at)))),
    CONSTRAINT orders_orders_exchange_rate_check CHECK ((exchange_rate > (0)::numeric)),
    CONSTRAINT orders_orders_lock_version_check CHECK ((lock_version >= 0)),
    CONSTRAINT orders_orders_paid_at_check CHECK (((((status)::text = ANY ((ARRAY['paid'::character varying, 'fulfilled'::character varying, 'partially_refunded'::character varying, 'refunded'::character varying])::text[])) AND (paid_at IS NOT NULL)) OR (((status)::text <> ALL ((ARRAY['paid'::character varying, 'fulfilled'::character varying, 'partially_refunded'::character varying, 'refunded'::character varying])::text[])) AND (paid_at IS NULL)))),
    CONSTRAINT orders_orders_replacement_self_check CHECK (((replaces_order_id IS NULL) OR (replaces_order_id <> id))),
    CONSTRAINT orders_orders_sales_channel_check CHECK (((sales_channel)::text = ANY ((ARRAY['online'::character varying, 'walk_up'::character varying, 'resale'::character varying])::text[]))),
    CONSTRAINT orders_orders_status_check CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'pending_payment'::character varying, 'paid'::character varying, 'fulfilled'::character varying, 'expired'::character varying, 'cancelled'::character varying, 'partially_refunded'::character varying, 'refunded'::character varying])::text[]))),
    CONSTRAINT orders_orders_total_reconciles CHECK ((total_minor = (((((subtotal_minor - discount_minor) - subsidy_minor) + fee_minor) + tax_minor) + adjustment_minor)))
);


--
-- Name: orders_payment_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders_payment_events (
    id uuid DEFAULT uuidv7() NOT NULL,
    payment_id uuid,
    provider character varying NOT NULL,
    provider_event_id character varying NOT NULL,
    event_type character varying NOT NULL,
    status character varying DEFAULT 'received'::character varying NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    payload_digest character varying(64) NOT NULL,
    occurred_at timestamp with time zone,
    received_at timestamp with time zone NOT NULL,
    processed_at timestamp with time zone,
    processing_error character varying,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT orders_payment_events_identity_check CHECK (((btrim((provider)::text) <> ''::text) AND (btrim((provider_event_id)::text) <> ''::text) AND (btrim((event_type)::text) <> ''::text))),
    CONSTRAINT orders_payment_events_payload_digest_check CHECK (((payload_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT orders_payment_events_processed_state_check CHECK (((((status)::text = 'processed'::text) AND (processed_at IS NOT NULL)) OR ((status)::text <> 'processed'::text))),
    CONSTRAINT orders_payment_events_status_check CHECK (((status)::text = ANY ((ARRAY['received'::character varying, 'processing'::character varying, 'processed'::character varying, 'failed'::character varying, 'ignored'::character varying])::text[])))
);


--
-- Name: orders_payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders_payments (
    id uuid DEFAULT uuidv7() NOT NULL,
    order_id uuid NOT NULL,
    attempt_number integer NOT NULL,
    provider character varying NOT NULL,
    payment_method character varying NOT NULL,
    status character varying DEFAULT 'created'::character varying NOT NULL,
    amount_minor bigint NOT NULL,
    currency character varying(3) NOT NULL,
    commercial_signature character varying(64) NOT NULL,
    buyer_fee_minor bigint DEFAULT 0 NOT NULL,
    organizer_fee_minor bigint DEFAULT 0 NOT NULL,
    provider_fee_minor bigint,
    provider_fee_currency character varying(3),
    idempotency_key character varying NOT NULL,
    provider_reference character varying,
    failure_code character varying,
    raw_status character varying,
    settlement_grace_minutes integer DEFAULT 5 NOT NULL,
    settlement_grace_expires_at timestamp with time zone NOT NULL,
    accepted_at timestamp with time zone,
    superseded_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT orders_payments_accepted_state_check CHECK (((accepted_at IS NULL) OR ((status)::text = 'succeeded'::text))),
    CONSTRAINT orders_payments_amounts_check CHECK (((amount_minor > 0) AND (buyer_fee_minor >= 0) AND (organizer_fee_minor >= 0) AND ((provider_fee_minor IS NULL) OR (provider_fee_minor >= 0)))),
    CONSTRAINT orders_payments_attempt_number_check CHECK (((attempt_number >= 1) AND (attempt_number <= 3))),
    CONSTRAINT orders_payments_commercial_signature_check CHECK (((commercial_signature)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT orders_payments_currency_check CHECK ((((currency)::text ~ '^[A-Z]{3}$'::text) AND ((provider_fee_currency IS NULL) OR ((provider_fee_currency)::text ~ '^[A-Z]{3}$'::text)))),
    CONSTRAINT orders_payments_grace_minutes_check CHECK (((settlement_grace_minutes >= 3) AND (settlement_grace_minutes <= 15))),
    CONSTRAINT orders_payments_provider_fee_pair_check CHECK ((((provider_fee_minor IS NULL) = (provider_fee_currency IS NULL)) AND ((provider_fee_minor IS NULL) OR ((provider_fee_currency)::text = (currency)::text)))),
    CONSTRAINT orders_payments_status_check CHECK (((status)::text = ANY ((ARRAY['created'::character varying, 'processing'::character varying, 'succeeded'::character varying, 'failed'::character varying, 'cancelled'::character varying, 'unknown'::character varying, 'timeout'::character varying, 'reversed'::character varying])::text[]))),
    CONSTRAINT orders_payments_superseded_state_check CHECK (((superseded_at IS NULL) OR ((status)::text <> ALL ((ARRAY['created'::character varying, 'processing'::character varying])::text[]))))
);


--
-- Name: orders_promotion_redemptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders_promotion_redemptions (
    id uuid DEFAULT uuidv7() NOT NULL,
    order_id uuid NOT NULL,
    promotion_id uuid NOT NULL,
    promotion_code_id uuid,
    user_id uuid NOT NULL,
    status character varying DEFAULT 'reserved'::character varying NOT NULL,
    discount_minor bigint NOT NULL,
    currency character varying(3) NOT NULL,
    idempotency_key character varying NOT NULL,
    expires_at timestamp with time zone,
    applied_at timestamp with time zone,
    released_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT promotion_redemptions_currency_check CHECK (((currency)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT promotion_redemptions_discount_check CHECK ((discount_minor > 0)),
    CONSTRAINT promotion_redemptions_state_check CHECK (((((status)::text = 'reserved'::text) AND (expires_at IS NOT NULL) AND (applied_at IS NULL) AND (released_at IS NULL)) OR (((status)::text = 'applied'::text) AND (applied_at IS NOT NULL) AND (released_at IS NULL)) OR (((status)::text = 'released'::text) AND (released_at IS NOT NULL) AND (applied_at IS NULL)) OR (((status)::text = 'expired'::text) AND (expires_at IS NOT NULL) AND (released_at IS NOT NULL) AND (applied_at IS NULL)))),
    CONSTRAINT promotion_redemptions_status_check CHECK (((status)::text = ANY ((ARRAY['reserved'::character varying, 'applied'::character varying, 'released'::character varying, 'expired'::character varying])::text[])))
);


--
-- Name: orders_refunds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders_refunds (
    id uuid DEFAULT uuidv7() NOT NULL,
    payment_id uuid NOT NULL,
    event_cancellation_id uuid,
    type character varying NOT NULL,
    idempotency_key character varying NOT NULL,
    provider_reference character varying,
    amount_minor bigint NOT NULL,
    currency character varying(3) NOT NULL,
    status character varying DEFAULT 'created'::character varying NOT NULL,
    provider_fee_minor bigint,
    provider_fee_currency character varying(3),
    provider_fee_recorded_at timestamp with time zone,
    pending_reason character varying,
    next_retry_at timestamp with time zone,
    reason_code character varying NOT NULL,
    reason text,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT orders_refunds_amount_currency_check CHECK (((amount_minor > 0) AND ((currency)::text ~ '^[A-Z]{3}$'::text))),
    CONSTRAINT orders_refunds_provider_fee_pair_check CHECK ((((provider_fee_minor IS NULL) AND (provider_fee_currency IS NULL) AND (provider_fee_recorded_at IS NULL)) OR ((provider_fee_minor IS NOT NULL) AND (provider_fee_minor >= 0) AND (provider_fee_currency IS NOT NULL) AND ((provider_fee_currency)::text ~ '^[A-Z]{3}$'::text) AND (provider_fee_recorded_at IS NOT NULL)))),
    CONSTRAINT orders_refunds_status_check CHECK (((status)::text = ANY ((ARRAY['created'::character varying, 'pending_funds'::character varying, 'processing'::character varying, 'succeeded'::character varying, 'failed'::character varying])::text[]))),
    CONSTRAINT orders_refunds_type_check CHECK (((type)::text = ANY ((ARRAY['item_refund'::character varying, 'payment_reversal'::character varying])::text[])))
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
    code_ciphertext text,
    idempotency_key_digest character varying(64),
    creation_request_digest character varying(64),
    CONSTRAINT ticketing_access_codes_idempotency_digests_check CHECK ((((idempotency_key_digest IS NULL) AND (creation_request_digest IS NULL)) OR (((idempotency_key_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((creation_request_digest)::text ~ '^[0-9a-f]{64}$'::text)))),
    CONSTRAINT ticketing_access_codes_max_quantity_check CHECK ((max_quantity_per_use >= 1)),
    CONSTRAINT ticketing_access_codes_max_uses_check CHECK (((max_uses IS NULL) OR (max_uses >= 1))),
    CONSTRAINT ticketing_access_codes_used_count_check CHECK ((used_count >= 0)),
    CONSTRAINT ticketing_access_codes_window_check CHECK (((expires_at IS NULL) OR (starts_at IS NULL) OR (expires_at > starts_at)))
);


--
-- Name: ticketing_admission_slots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_admission_slots (
    id uuid DEFAULT uuidv7() NOT NULL,
    ticket_id uuid NOT NULL,
    "position" smallint NOT NULL,
    assigned_user_id uuid,
    assignment_status character varying DEFAULT 'unassigned'::character varying NOT NULL,
    claimed_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_admission_slots_claimed_at_check CHECK (((((assignment_status)::text = 'claimed'::text) AND (claimed_at IS NOT NULL)) OR (((assignment_status)::text <> 'claimed'::text) AND (claimed_at IS NULL)))),
    CONSTRAINT ticketing_admission_slots_position_check CHECK (("position" > 0)),
    CONSTRAINT ticketing_admission_slots_status_check CHECK (((assignment_status)::text = ANY ((ARRAY['unassigned'::character varying, 'pending_claim'::character varying, 'claimed'::character varying])::text[])))
);


--
-- Name: ticketing_admission_use_reversals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_admission_use_reversals (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    admission_use_id uuid NOT NULL,
    checkin_log_id uuid NOT NULL,
    reversal_group_id uuid NOT NULL,
    reversed_by_id uuid NOT NULL,
    reason_code character varying NOT NULL,
    note text,
    reversal_version bigint NOT NULL,
    reversed_at timestamp with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_admission_use_reversals_reason_check CHECK ((btrim((reason_code)::text) <> ''::text)),
    CONSTRAINT ticketing_admission_use_reversals_version_check CHECK ((reversal_version > 0))
);


--
-- Name: ticketing_admission_uses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_admission_uses (
    id uuid DEFAULT uuidv7() NOT NULL,
    admission_slot_id uuid NOT NULL,
    product_access_id uuid NOT NULL,
    credential_id uuid NOT NULL,
    checkin_log_id uuid NOT NULL,
    usage_number integer NOT NULL,
    used_at timestamp with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_admission_uses_usage_number_check CHECK ((usage_number > 0))
);


--
-- Name: ticketing_attendee_exports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_attendee_exports (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    requested_by_id uuid NOT NULL,
    status character varying NOT NULL,
    row_mode character varying NOT NULL,
    format_version character varying NOT NULL,
    field_keys jsonb,
    filters jsonb,
    field_set_digest character varying NOT NULL,
    filter_digest character varying NOT NULL,
    reason_code character varying NOT NULL,
    data_cutoff_at timestamp(6) with time zone NOT NULL,
    row_count integer,
    file_sha256 character varying,
    idempotency_key_digest character varying NOT NULL,
    request_fingerprint character varying NOT NULL,
    digest_key_version character varying NOT NULL,
    processing_started_at timestamp(6) with time zone,
    attempt_count integer DEFAULT 0 NOT NULL,
    ready_at timestamp(6) with time zone,
    failed_at timestamp(6) with time zone,
    expiring_at timestamp(6) with time zone,
    expired_at timestamp(6) with time zone,
    expires_at timestamp(6) with time zone NOT NULL,
    last_download_authorized_at timestamp(6) with time zone,
    failure_code character varying,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_attendee_exports_attempt_count_check CHECK (((attempt_count >= 0) AND (attempt_count <= 3))),
    CONSTRAINT ticketing_attendee_exports_digest_key_version_check CHECK (((digest_key_version)::text ~ '^v[0-9]+$'::text)),
    CONSTRAINT ticketing_attendee_exports_expiry_window_check CHECK (((expires_at > data_cutoff_at) AND (expires_at <= (data_cutoff_at + '24:00:00'::interval)))),
    CONSTRAINT ticketing_attendee_exports_failure_code_check CHECK (((failure_code IS NULL) OR ((failure_code)::text = ANY ((ARRAY['generation_failed'::character varying, 'export_too_large'::character varying, 'export_generation_failed'::character varying, 'export_storage_unavailable'::character varying])::text[])))),
    CONSTRAINT ticketing_attendee_exports_field_keys_shape_check CHECK (((field_keys IS NULL) OR ((jsonb_typeof(field_keys) = 'array'::text) AND (jsonb_array_length(field_keys) <= 100)))),
    CONSTRAINT ticketing_attendee_exports_field_set_digest_check CHECK (((field_set_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT ticketing_attendee_exports_file_digest_shape_check CHECK (((file_sha256 IS NULL) OR ((file_sha256)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT ticketing_attendee_exports_filter_digest_check CHECK (((filter_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT ticketing_attendee_exports_filters_shape_check CHECK (((jsonb_typeof(filters) = 'object'::text) OR (filters IS NULL))),
    CONSTRAINT ticketing_attendee_exports_format_version_check CHECK (((format_version)::text = 'csv_v1'::text)),
    CONSTRAINT ticketing_attendee_exports_idempotency_digest_check CHECK (((idempotency_key_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT ticketing_attendee_exports_payload_state_check CHECK (((((status)::text = 'expired'::text) AND (field_keys IS NULL) AND (filters IS NULL)) OR (((status)::text <> 'expired'::text) AND (field_keys IS NOT NULL) AND (filters IS NOT NULL)))),
    CONSTRAINT ticketing_attendee_exports_reason_code_check CHECK (((reason_code)::text = ANY ((ARRAY['event_operations'::character varying, 'attendee_communication'::character varying, 'dietary_accommodation'::character varying, 'accessibility_accommodation'::character varying, 'customer_support'::character varying, 'legal_compliance'::character varying])::text[]))),
    CONSTRAINT ticketing_attendee_exports_request_fingerprint_check CHECK (((request_fingerprint)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT ticketing_attendee_exports_row_count_check CHECK (((row_count IS NULL) OR (row_count >= 0))),
    CONSTRAINT ticketing_attendee_exports_row_mode_check CHECK (((row_mode)::text = ANY ((ARRAY['registration'::character varying, 'admission'::character varying])::text[]))),
    CONSTRAINT ticketing_attendee_exports_state_timestamps_check CHECK (((((status)::text = 'pending'::text) AND (processing_started_at IS NULL) AND (ready_at IS NULL) AND (failed_at IS NULL) AND (expiring_at IS NULL) AND (expired_at IS NULL)) OR (((status)::text = 'processing'::text) AND (processing_started_at IS NOT NULL) AND (ready_at IS NULL) AND (failed_at IS NULL) AND (expiring_at IS NULL) AND (expired_at IS NULL)) OR (((status)::text = 'ready'::text) AND (processing_started_at IS NOT NULL) AND (ready_at IS NOT NULL) AND (failed_at IS NULL) AND (expiring_at IS NULL) AND (expired_at IS NULL) AND (row_count IS NOT NULL) AND (file_sha256 IS NOT NULL)) OR (((status)::text = 'failed'::text) AND (processing_started_at IS NOT NULL) AND (ready_at IS NULL) AND (failed_at IS NOT NULL) AND (expiring_at IS NULL) AND (expired_at IS NULL)) OR (((status)::text = 'expiring'::text) AND (expiring_at IS NOT NULL) AND (expired_at IS NULL)) OR (((status)::text = 'expired'::text) AND (expired_at IS NOT NULL)))),
    CONSTRAINT ticketing_attendee_exports_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'processing'::character varying, 'ready'::character varying, 'failed'::character varying, 'expiring'::character varying, 'expired'::character varying])::text[])))
);


--
-- Name: ticketing_attendee_index_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_attendee_index_entries (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    lookup_code character varying(8) NOT NULL,
    phone_hash character varying(64),
    owner_phone_hash character varying(64),
    holder_name text,
    credential_id uuid NOT NULL,
    ticket_id uuid NOT NULL,
    slot_positions smallint[] DEFAULT '{}'::smallint[] NOT NULL,
    credential_mode character varying NOT NULL,
    generation_version integer NOT NULL,
    entry_limit smallint NOT NULL,
    ticket_type character varying NOT NULL,
    ticket_type_label character varying,
    perks jsonb DEFAULT '[]'::jsonb NOT NULL,
    product_access_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    entry_validation_mode character varying DEFAULT 'qr'::character varying NOT NULL,
    index_version bigint DEFAULT 0 NOT NULL,
    removed boolean DEFAULT false NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_attendee_index_entries_mode_check CHECK (((credential_mode)::text = ANY ((ARRAY['group'::character varying, 'delegated'::character varying])::text[]))),
    CONSTRAINT ticketing_attendee_index_entries_owner_phone_hash_check CHECK (((owner_phone_hash IS NULL) OR ((owner_phone_hash)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT ticketing_attendee_index_entries_phone_hash_check CHECK (((phone_hash IS NULL) OR ((phone_hash)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT ticketing_attendee_index_entries_shape_check CHECK (((cardinality(slot_positions) > 0) AND (entry_limit = cardinality(slot_positions)) AND (entry_limit > 0) AND (generation_version > 0) AND (index_version >= 0))),
    CONSTRAINT ticketing_attendee_index_entries_validation_mode_check CHECK (((entry_validation_mode)::text = ANY ((ARRAY['qr'::character varying, 'qr_and_id'::character varying])::text[])))
);


--
-- Name: ticketing_checkin_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_checkin_logs (
    id uuid DEFAULT uuidv7() NOT NULL,
    ticket_id uuid NOT NULL,
    credential_id uuid NOT NULL,
    credential_version integer NOT NULL,
    product_access_id uuid NOT NULL,
    event_date_id uuid NOT NULL,
    access_zone_id uuid,
    scanner_device_assignment_id uuid,
    scan_upload_id uuid,
    client_scan_id uuid NOT NULL,
    result character varying NOT NULL,
    lookup_via character varying NOT NULL,
    reason_code character varying,
    identity_check_result character varying DEFAULT 'not_required'::character varying NOT NULL,
    identity_checked_by_id uuid,
    overrides_checkin_log_id uuid,
    identity_override_by_id uuid,
    identity_override_reason character varying,
    identity_overridden_at timestamp with time zone,
    scanned_at timestamp with time zone NOT NULL,
    received_at timestamp with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_checkin_logs_credential_version_check CHECK ((credential_version > 0)),
    CONSTRAINT ticketing_checkin_logs_identity_check_shape CHECK (((((identity_check_result)::text = 'not_required'::text) AND (identity_checked_by_id IS NULL)) OR (((identity_check_result)::text = ANY ((ARRAY['matched'::character varying, 'mismatch'::character varying])::text[])) AND (identity_checked_by_id IS NOT NULL)))),
    CONSTRAINT ticketing_checkin_logs_identity_override_shape CHECK ((((identity_override_by_id IS NULL) AND (identity_override_reason IS NULL) AND (identity_overridden_at IS NULL) AND (overrides_checkin_log_id IS NULL)) OR ((identity_override_by_id IS NOT NULL) AND ((identity_check_result)::text = 'mismatch'::text) AND ((result)::text = 'success'::text) AND (btrim((identity_override_reason)::text) <> ''::text) AND (identity_overridden_at IS NOT NULL) AND (overrides_checkin_log_id IS NOT NULL) AND (scan_upload_id IS NULL)))),
    CONSTRAINT ticketing_checkin_logs_identity_result_check CHECK (((identity_check_result)::text = ANY ((ARRAY['not_required'::character varying, 'matched'::character varying, 'mismatch'::character varying])::text[]))),
    CONSTRAINT ticketing_checkin_logs_lookup_via_check CHECK (((lookup_via)::text = ANY ((ARRAY['qr'::character varying, 'code'::character varying, 'phone'::character varying, 'name'::character varying])::text[]))),
    CONSTRAINT ticketing_checkin_logs_manual_reason_check CHECK ((((lookup_via)::text = 'qr'::text) OR (btrim((reason_code)::text) <> ''::text))),
    CONSTRAINT ticketing_checkin_logs_result_check CHECK (((result)::text = ANY ((ARRAY['success'::character varying, 'duplicate'::character varying, 'invalid'::character varying, 'version_mismatch'::character varying, 'revoked'::character varying, 'wrong_date'::character varying, 'wrong_channel'::character varying, 'wrong_zone'::character varying, 'identity_mismatch'::character varying])::text[])))
);


--
-- Name: ticketing_credential_claims; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_credential_claims (
    id uuid DEFAULT uuidv7() NOT NULL,
    credential_id uuid NOT NULL,
    invited_user_id uuid,
    claimed_by_user_id uuid,
    contact_digest character varying(64) NOT NULL,
    token_digest character varying(64) NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    expires_at timestamp with time zone,
    accepted_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_credential_claims_acceptance_check CHECK ((((status)::text <> 'accepted'::text) OR ((claimed_by_user_id IS NOT NULL) AND (accepted_at IS NOT NULL)))),
    CONSTRAINT ticketing_credential_claims_digest_check CHECK ((((contact_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((token_digest)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT ticketing_credential_claims_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'accepted'::character varying, 'revoked'::character varying, 'expired'::character varying])::text[])))
);


--
-- Name: ticketing_credential_generations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_credential_generations (
    id uuid DEFAULT uuidv7() NOT NULL,
    ticket_id uuid NOT NULL,
    version integer NOT NULL,
    mode character varying NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    activated_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    revocation_reason character varying,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_credential_generations_mode_check CHECK (((mode)::text = ANY ((ARRAY['group'::character varying, 'delegated'::character varying])::text[]))),
    CONSTRAINT ticketing_credential_generations_revocation_check CHECK (((((status)::text = 'active'::text) AND (revoked_at IS NULL)) OR (((status)::text = 'revoked'::text) AND (revoked_at IS NOT NULL)))),
    CONSTRAINT ticketing_credential_generations_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'revoked'::character varying])::text[]))),
    CONSTRAINT ticketing_credential_generations_version_check CHECK ((version > 0))
);


--
-- Name: ticketing_credential_revocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_credential_revocations (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    credential_id uuid NOT NULL,
    reason character varying NOT NULL,
    revoked_at timestamp with time zone NOT NULL,
    revocation_version bigint DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_credential_revocations_values_check CHECK (((revocation_version >= 0) AND ((reason)::text <> ''::text)))
);


--
-- Name: ticketing_credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_credentials (
    id uuid DEFAULT uuidv7() NOT NULL,
    ticket_id uuid NOT NULL,
    credential_generation_id uuid NOT NULL,
    admission_slot_id uuid,
    event_id uuid NOT NULL,
    type character varying NOT NULL,
    holder_user_id uuid,
    holder_name text,
    status character varying DEFAULT 'pending_claim'::character varying NOT NULL,
    slot_positions smallint[] DEFAULT '{}'::smallint[] NOT NULL,
    entry_limit smallint NOT NULL,
    qr_token text,
    lookup_code character varying(8),
    issued_at timestamp with time zone,
    revoked_at timestamp with time zone,
    revocation_reason character varying,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_credentials_activation_check CHECK (((((status)::text = ANY ((ARRAY['pending_claim'::character varying, 'pending_requirements'::character varying])::text[])) AND (qr_token IS NULL) AND (lookup_code IS NULL) AND (issued_at IS NULL)) OR (((status)::text = 'active'::text) AND (qr_token IS NOT NULL) AND (lookup_code IS NOT NULL) AND (issued_at IS NOT NULL)) OR ((status)::text = 'revoked'::text))),
    CONSTRAINT ticketing_credentials_admission_slot_check CHECK (((((type)::text = 'package'::text) AND (admission_slot_id IS NULL)) OR (((type)::text = 'individual'::text) AND (admission_slot_id IS NOT NULL) AND (entry_limit = 1)))),
    CONSTRAINT ticketing_credentials_revocation_check CHECK (((((status)::text = 'revoked'::text) AND (revoked_at IS NOT NULL)) OR (((status)::text <> 'revoked'::text) AND (revoked_at IS NULL)))),
    CONSTRAINT ticketing_credentials_slot_shape_check CHECK (((cardinality(slot_positions) > 0) AND (entry_limit = cardinality(slot_positions)) AND (entry_limit > 0))),
    CONSTRAINT ticketing_credentials_status_check CHECK (((status)::text = ANY ((ARRAY['pending_claim'::character varying, 'pending_requirements'::character varying, 'active'::character varying, 'revoked'::character varying])::text[]))),
    CONSTRAINT ticketing_credentials_type_check CHECK (((type)::text = ANY ((ARRAY['package'::character varying, 'individual'::character varying])::text[])))
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
    token_ciphertext text NOT NULL,
    idempotency_key_digest character varying(64),
    creation_request_digest character varying(64),
    CONSTRAINT ticketing_invitations_allowed_quantity_check CHECK ((allowed_quantity >= 1)),
    CONSTRAINT ticketing_invitations_idempotency_digests_check CHECK ((((idempotency_key_digest IS NULL) AND (creation_request_digest IS NULL)) OR (((idempotency_key_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((creation_request_digest)::text ~ '^[0-9a-f]{64}$'::text)))),
    CONSTRAINT ticketing_invitations_status_check CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('accepted'::character varying)::text, ('revoked'::character varying)::text, ('expired'::character varying)::text])))
);


--
-- Name: ticketing_purchase_limit_allocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_purchase_limit_allocations (
    id uuid DEFAULT uuidv7() NOT NULL,
    ticket_type_id uuid NOT NULL,
    user_id uuid NOT NULL,
    scope_event_date_id uuid,
    registration_id uuid NOT NULL,
    unit_number integer NOT NULL,
    ticket_id uuid,
    status character varying NOT NULL,
    expires_at timestamp with time zone,
    committed_at timestamp with time zone,
    released_at timestamp with time zone,
    release_reason character varying,
    idempotency_key character varying NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_purchase_limit_allocations_release_reason_check CHECK (((release_reason IS NULL) OR ((release_reason)::text = ANY ((ARRAY['expired'::character varying, 'checkout_expired'::character varying, 'cancelled'::character varying, 'refunded'::character varying, 'void'::character varying, 'resale_replaced'::character varying])::text[])))),
    CONSTRAINT ticketing_purchase_limit_allocations_state_check CHECK (((((status)::text = 'reserved'::text) AND (expires_at IS NOT NULL) AND (committed_at IS NULL) AND (released_at IS NULL) AND (release_reason IS NULL)) OR (((status)::text = 'committed'::text) AND (expires_at IS NULL) AND (committed_at IS NOT NULL) AND (released_at IS NULL) AND (release_reason IS NULL)) OR (((status)::text = 'released'::text) AND (expires_at IS NULL) AND (committed_at IS NULL) AND (released_at IS NOT NULL) AND (release_reason IS NOT NULL) AND ((release_reason)::text <> ''::text)))),
    CONSTRAINT ticketing_purchase_limit_allocations_status_check CHECK (((status)::text = ANY ((ARRAY['reserved'::character varying, 'committed'::character varying, 'released'::character varying])::text[]))),
    CONSTRAINT ticketing_purchase_limit_allocations_unit_check CHECK ((unit_number > 0))
);


--
-- Name: ticketing_purchase_limit_overrides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_purchase_limit_overrides (
    id uuid DEFAULT uuidv7() NOT NULL,
    registration_id uuid NOT NULL,
    ticket_type_id uuid NOT NULL,
    user_id uuid NOT NULL,
    scope_event_date_id uuid,
    additional_packages integer NOT NULL,
    approved_by_id uuid NOT NULL,
    reason_code character varying NOT NULL,
    idempotency_key character varying NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_purchase_limit_overrides_packages_check CHECK ((additional_packages > 0)),
    CONSTRAINT ticketing_purchase_limit_overrides_reason_check CHECK (((reason_code)::text = ANY ((ARRAY['accessibility'::character varying, 'accommodation'::character varying, 'community_partner'::character varying, 'service_recovery'::character varying, 'sponsor_guest'::character varying, 'staff_guest'::character varying, 'organizer_exception'::character varying])::text[])))
);


--
-- Name: ticketing_registration_answer_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_registration_answer_revisions (
    id uuid DEFAULT uuidv7() NOT NULL,
    registration_answer_id uuid CONSTRAINT ticketing_registration_answer_r_registration_answer_id_not_null NOT NULL,
    revision_number integer CONSTRAINT ticketing_registration_answer_revision_revision_number_not_null NOT NULL,
    answer_ciphertext text,
    revised_by_id uuid NOT NULL,
    source character varying NOT NULL,
    reason_code character varying,
    revised_at timestamp with time zone NOT NULL,
    erased_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    idempotency_key_digest character varying(64) CONSTRAINT ticketing_registration_answer_r_idempotency_key_digest_not_null NOT NULL,
    request_digest character varying(64) NOT NULL,
    retain_until timestamp with time zone,
    CONSTRAINT ticketing_registration_answer_revisions_digest_check CHECK ((((idempotency_key_digest)::text ~ '^[0-9a-f]{64}$'::text) AND ((request_digest)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT ticketing_registration_answer_revisions_erasure_check CHECK ((((erased_at IS NULL) AND (answer_ciphertext IS NOT NULL)) OR ((erased_at IS NOT NULL) AND (answer_ciphertext IS NULL)))),
    CONSTRAINT ticketing_registration_answer_revisions_manager_reason_check CHECK ((((source)::text <> 'manager_correction'::text) OR (reason_code IS NOT NULL))),
    CONSTRAINT ticketing_registration_answer_revisions_positive_number_check CHECK ((revision_number > 0)),
    CONSTRAINT ticketing_registration_answer_revisions_reason_code_check CHECK (((reason_code IS NULL) OR ((reason_code)::text = ANY ((ARRAY['attendee_request'::character varying, 'data_quality'::character varying, 'legal_requirement'::character varying, 'accessibility_correction'::character varying])::text[])))),
    CONSTRAINT ticketing_registration_answer_revisions_source_check CHECK (((source)::text = ANY ((ARRAY['attendee_correction'::character varying, 'manager_correction'::character varying])::text[])))
);


--
-- Name: ticketing_registration_answers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_registration_answers (
    id uuid DEFAULT uuidv7() NOT NULL,
    registration_form_submission_id uuid CONSTRAINT ticketing_registration_answ_registration_form_submissi_not_null NOT NULL,
    registration_question_id uuid CONSTRAINT ticketing_registration_answer_registration_question_id_not_null NOT NULL,
    question_key_snapshot character varying NOT NULL,
    question_type_snapshot character varying NOT NULL,
    response_scope_snapshot character varying NOT NULL,
    question_label_snapshot character varying NOT NULL,
    package_unit_number integer,
    admission_position smallint,
    admission_slot_id uuid,
    answer_ciphertext text,
    retention_policy_id uuid NOT NULL,
    retain_until timestamp with time zone,
    answered_at timestamp with time zone NOT NULL,
    erased_at timestamp with time zone,
    erasure_reason character varying,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_registration_answers_erasure_check CHECK ((((erased_at IS NULL) AND (erasure_reason IS NULL) AND (answer_ciphertext IS NOT NULL)) OR ((erased_at IS NOT NULL) AND (erasure_reason IS NOT NULL) AND (answer_ciphertext IS NULL)))),
    CONSTRAINT ticketing_registration_answers_erasure_reason_check CHECK (((erasure_reason IS NULL) OR ((erasure_reason)::text = ANY ((ARRAY['legal_request'::character varying, 'policy_expiry'::character varying, 'privacy_request'::character varying, 'security_incident'::character varying])::text[])))),
    CONSTRAINT ticketing_registration_answers_question_type_check CHECK (((question_type_snapshot)::text = ANY ((ARRAY['short_text'::character varying, 'long_text'::character varying, 'single_choice'::character varying, 'multiple_choice'::character varying, 'checkbox'::character varying, 'date'::character varying])::text[]))),
    CONSTRAINT ticketing_registration_answers_response_scope_check CHECK (((response_scope_snapshot)::text = ANY ((ARRAY['registration'::character varying, 'admission_slot'::character varying])::text[]))),
    CONSTRAINT ticketing_registration_answers_scope_coordinates_check CHECK (((((response_scope_snapshot)::text = 'registration'::text) AND (package_unit_number IS NULL) AND (admission_position IS NULL) AND (admission_slot_id IS NULL)) OR (((response_scope_snapshot)::text = 'admission_slot'::text) AND (package_unit_number > 0) AND (admission_position > 0))))
);


--
-- Name: ticketing_registration_consent_requirements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_registration_consent_requirements (
    id uuid DEFAULT uuidv7() NOT NULL,
    registration_id uuid CONSTRAINT ticketing_registration_consent_require_registration_id_not_null NOT NULL,
    consent_document_version_id uuid CONSTRAINT ticketing_registration_cons_consent_document_version_i_not_null NOT NULL,
    required boolean DEFAULT true NOT NULL,
    acceptance_scope character varying CONSTRAINT ticketing_registration_consent_requir_acceptance_scope_not_null NOT NULL,
    package_unit_number integer,
    admission_position smallint,
    admission_slot_id uuid,
    subject_user_id uuid,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    supersedes_requirement_id uuid,
    required_reason character varying DEFAULT 'initial_submission'::character varying CONSTRAINT ticketing_registration_consent_require_required_reason_not_null NOT NULL,
    required_by_id uuid,
    required_at timestamp with time zone CONSTRAINT ticketing_registration_consent_requirement_required_at_not_null NOT NULL,
    superseded_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_consent_requirements_coordinate_check CHECK (((((acceptance_scope)::text = 'buyer'::text) AND (package_unit_number IS NULL) AND (admission_position IS NULL) AND (admission_slot_id IS NULL) AND (subject_user_id IS NOT NULL)) OR (((acceptance_scope)::text = 'admission_slot'::text) AND (package_unit_number > 0) AND (admission_position > 0)))),
    CONSTRAINT ticketing_consent_requirements_reason_check CHECK (((required_reason)::text = ANY ((ARRAY['initial_submission'::character varying, 'reconsent'::character varying])::text[]))),
    CONSTRAINT ticketing_consent_requirements_required_by_check CHECK ((((required_reason)::text = 'initial_submission'::text) OR (required_by_id IS NOT NULL))),
    CONSTRAINT ticketing_consent_requirements_scope_check CHECK (((acceptance_scope)::text = ANY ((ARRAY['buyer'::character varying, 'admission_slot'::character varying])::text[]))),
    CONSTRAINT ticketing_consent_requirements_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'accepted'::character varying, 'withdrawn'::character varying, 'superseded'::character varying])::text[]))),
    CONSTRAINT ticketing_consent_requirements_subject_check CHECK ((((status)::text <> ALL ((ARRAY['accepted'::character varying, 'withdrawn'::character varying])::text[])) OR (subject_user_id IS NOT NULL))),
    CONSTRAINT ticketing_consent_requirements_superseded_at_check CHECK (((((status)::text = 'superseded'::text) AND (superseded_at IS NOT NULL)) OR (((status)::text <> 'superseded'::text) AND (superseded_at IS NULL))))
);


--
-- Name: ticketing_registration_consent_withdrawals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_registration_consent_withdrawals (
    id uuid DEFAULT uuidv7() NOT NULL,
    registration_consent_id uuid CONSTRAINT ticketing_registration_consent_registration_consent_id_not_null NOT NULL,
    registration_id uuid CONSTRAINT ticketing_registration_consent_withdra_registration_id_not_null NOT NULL,
    withdrawn_by_user_id uuid CONSTRAINT ticketing_registration_consent_wi_withdrawn_by_user_id_not_null NOT NULL,
    reason_code character varying,
    idempotency_key character varying(64) CONSTRAINT ticketing_registration_consent_withdra_idempotency_key_not_null NOT NULL,
    withdrawn_at timestamp with time zone CONSTRAINT ticketing_registration_consent_withdrawal_withdrawn_at_not_null NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_consent_withdrawals_idempotency_digest_check CHECK (((idempotency_key)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT ticketing_consent_withdrawals_reason_check CHECK (((reason_code IS NULL) OR ((reason_code)::text = ANY ((ARRAY['attendee_request'::character varying, 'privacy_request'::character varying, 'legal_request'::character varying, 'changed_mind'::character varying])::text[]))))
);


--
-- Name: ticketing_registration_consents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_registration_consents (
    id uuid DEFAULT uuidv7() NOT NULL,
    registration_consent_requirement_id uuid CONSTRAINT ticketing_registration_cons_registration_consent_requi_not_null NOT NULL,
    registration_id uuid NOT NULL,
    accepted_by_user_id uuid NOT NULL,
    signer_role character varying NOT NULL,
    acceptance_method character varying DEFAULT 'otp'::character varying NOT NULL,
    content_sha256 character varying(64) NOT NULL,
    evidence_digest character varying(64) NOT NULL,
    idempotency_key_digest character varying(64) NOT NULL,
    request_uuid uuid NOT NULL,
    retention_policy_id uuid NOT NULL,
    retain_until timestamp with time zone,
    accepted_at timestamp with time zone NOT NULL,
    erased_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_registration_consents_acceptance_method_check CHECK (((acceptance_method)::text = ANY ((ARRAY['checkbox'::character varying, 'otp'::character varying])::text[]))),
    CONSTRAINT ticketing_registration_consents_digest_check CHECK ((((content_sha256)::text ~ '^[0-9a-f]{64}$'::text) AND ((evidence_digest)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT ticketing_registration_consents_erasure_time_check CHECK (((erased_at IS NULL) OR (erased_at >= accepted_at))),
    CONSTRAINT ticketing_registration_consents_idempotency_digest_check CHECK (((idempotency_key_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT ticketing_registration_consents_retention_window_check CHECK (((retain_until IS NULL) OR (retain_until > accepted_at))),
    CONSTRAINT ticketing_registration_consents_signer_role_check CHECK (((signer_role)::text = ANY ((ARRAY['buyer'::character varying, 'attendee'::character varying])::text[])))
);


--
-- Name: ticketing_registration_form_submissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_registration_form_submissions (
    id uuid DEFAULT uuidv7() NOT NULL,
    registration_id uuid CONSTRAINT ticketing_registration_form_submission_registration_id_not_null NOT NULL,
    registration_form_version_id uuid CONSTRAINT ticketing_registration_form_registration_form_version__not_null NOT NULL,
    submitted_by_user_id uuid CONSTRAINT ticketing_registration_form_submi_submitted_by_user_id_not_null NOT NULL,
    submitted_at timestamp with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: ticketing_registration_form_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_registration_form_versions (
    id uuid DEFAULT uuidv7() NOT NULL,
    registration_form_id uuid CONSTRAINT ticketing_registration_form_versi_registration_form_id_not_null NOT NULL,
    version integer NOT NULL,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    published_by_id uuid,
    published_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_registration_form_versions_positive_version_check CHECK ((version > 0)),
    CONSTRAINT ticketing_registration_form_versions_publish_metadata_check CHECK (((((status)::text = 'draft'::text) AND (published_by_id IS NULL) AND (published_at IS NULL)) OR (((status)::text = ANY ((ARRAY['published'::character varying, 'retired'::character varying])::text[])) AND (published_by_id IS NOT NULL) AND (published_at IS NOT NULL)))),
    CONSTRAINT ticketing_registration_form_versions_status_check CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'published'::character varying, 'retired'::character varying])::text[])))
);


--
-- Name: ticketing_registration_forms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_registration_forms (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    ticket_type_id uuid,
    name character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: ticketing_registration_questions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_registration_questions (
    id uuid DEFAULT uuidv7() NOT NULL,
    registration_form_version_id uuid CONSTRAINT ticketing_registration_ques_registration_form_version__not_null NOT NULL,
    key character varying NOT NULL,
    type character varying NOT NULL,
    response_scope character varying NOT NULL,
    sensitivity character varying NOT NULL,
    label character varying NOT NULL,
    help_text text,
    required boolean DEFAULT false NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    options jsonb DEFAULT '[]'::jsonb NOT NULL,
    validation_rules jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_registration_questions_json_shape_check CHECK (((jsonb_typeof(options) = 'array'::text) AND (jsonb_typeof(validation_rules) = 'object'::text))),
    CONSTRAINT ticketing_registration_questions_position_check CHECK (("position" >= 0)),
    CONSTRAINT ticketing_registration_questions_response_scope_check CHECK (((response_scope)::text = ANY ((ARRAY['registration'::character varying, 'admission_slot'::character varying])::text[]))),
    CONSTRAINT ticketing_registration_questions_sensitivity_check CHECK (((sensitivity)::text = ANY ((ARRAY['standard'::character varying, 'dietary'::character varying, 'accessibility'::character varying])::text[]))),
    CONSTRAINT ticketing_registration_questions_type_check CHECK (((type)::text = ANY ((ARRAY['short_text'::character varying, 'long_text'::character varying, 'single_choice'::character varying, 'multiple_choice'::character varying, 'checkbox'::character varying, 'date'::character varying])::text[])))
);


--
-- Name: ticketing_registrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_registrations (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    ticket_type_id uuid NOT NULL,
    user_id uuid NOT NULL,
    selected_event_date_id uuid,
    access_code_id uuid,
    invitation_id uuid,
    source character varying NOT NULL,
    created_by_id uuid NOT NULL,
    issuance_idempotency_key character varying,
    complimentary_reason character varying,
    identity_digest character varying(64) NOT NULL,
    package_quantity integer DEFAULT 1 NOT NULL,
    admissions_per_unit_snapshot smallint NOT NULL,
    party_size integer NOT NULL,
    status character varying DEFAULT 'pending_payment'::character varying NOT NULL,
    submitted_at timestamp with time zone NOT NULL,
    waitlisted_at timestamp with time zone,
    offered_at timestamp with time zone,
    offer_expires_at timestamp with time zone,
    reviewed_by_id uuid,
    approved_at timestamp with time zone,
    rejected_at timestamp with time zone,
    decision_reason text,
    confirmed_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_registrations_complimentary_reason_check CHECK (((complimentary_reason IS NULL) OR ((complimentary_reason)::text = ANY ((ARRAY['accessibility'::character varying, 'accommodation'::character varying, 'community_partner'::character varying, 'service_recovery'::character varying, 'sponsor_guest'::character varying, 'staff_guest'::character varying])::text[])))),
    CONSTRAINT ticketing_registrations_decision_exclusive_check CHECK ((NOT ((approved_at IS NOT NULL) AND (rejected_at IS NOT NULL)))),
    CONSTRAINT ticketing_registrations_identity_digest_check CHECK (((identity_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT ticketing_registrations_party_size_check CHECK ((party_size = (package_quantity * admissions_per_unit_snapshot))),
    CONSTRAINT ticketing_registrations_quantities_positive_check CHECK (((package_quantity > 0) AND (admissions_per_unit_snapshot > 0) AND (party_size > 0))),
    CONSTRAINT ticketing_registrations_source_check CHECK (((source)::text = ANY ((ARRAY['self_service'::character varying, 'organizer_complimentary'::character varying, 'walk_up'::character varying])::text[]))),
    CONSTRAINT ticketing_registrations_source_metadata_check CHECK (((((source)::text = 'organizer_complimentary'::text) AND (complimentary_reason IS NOT NULL) AND ((complimentary_reason)::text <> ''::text) AND (issuance_idempotency_key IS NOT NULL) AND ((issuance_idempotency_key)::text <> ''::text)) OR (((source)::text <> 'organizer_complimentary'::text) AND (complimentary_reason IS NULL)))),
    CONSTRAINT ticketing_registrations_state_timestamps_check CHECK ((((((status)::text = 'waitlisted'::text) AND (waitlisted_at IS NOT NULL)) OR (((status)::text <> 'waitlisted'::text) AND (waitlisted_at IS NULL))) AND ((((status)::text = 'offered'::text) AND (offered_at IS NOT NULL) AND (offer_expires_at IS NOT NULL) AND (offer_expires_at > offered_at)) OR (((status)::text <> 'offered'::text) AND (offered_at IS NULL) AND (offer_expires_at IS NULL))))),
    CONSTRAINT ticketing_registrations_status_check CHECK (((status)::text = ANY ((ARRAY['pending_payment'::character varying, 'pending_approval'::character varying, 'waitlisted'::character varying, 'offered'::character varying, 'confirmed'::character varying, 'rejected'::character varying, 'cancelled'::character varying, 'expired'::character varying])::text[])))
);


--
-- Name: ticketing_revocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_revocations (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    ticket_id uuid NOT NULL,
    revoked_through_version integer DEFAULT 0 NOT NULL,
    is_dead boolean DEFAULT false NOT NULL,
    is_suspended boolean DEFAULT false NOT NULL,
    revocation_version bigint DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_revocations_versions_check CHECK (((revoked_through_version >= 0) AND (revocation_version >= 0)))
);


--
-- Name: ticketing_scan_uploads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_scan_uploads (
    id uuid DEFAULT uuidv7() NOT NULL,
    scanner_device_assignment_id uuid NOT NULL,
    client_upload_id uuid NOT NULL,
    received_at timestamp with time zone NOT NULL,
    completed_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_scan_uploads_completion_check CHECK (((completed_at IS NULL) OR (completed_at >= received_at)))
);


--
-- Name: ticketing_scanner_assignment_zones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_scanner_assignment_zones (
    id uuid DEFAULT uuidv7() NOT NULL,
    scanner_device_assignment_id uuid CONSTRAINT ticketing_scanner_assignmen_scanner_device_assignment__not_null NOT NULL,
    access_zone_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: ticketing_scanner_device_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_scanner_device_assignments (
    id uuid DEFAULT uuidv7() NOT NULL,
    scanner_device_id uuid NOT NULL,
    event_id uuid NOT NULL,
    assigned_by_id uuid NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    starts_at timestamp with time zone,
    ends_at timestamp with time zone,
    last_revocation_version bigint DEFAULT 0 CONSTRAINT ticketing_scanner_device_assig_last_revocation_version_not_null NOT NULL,
    last_attendee_index_version bigint DEFAULT 0 CONSTRAINT ticketing_scanner_device_as_last_attendee_index_versio_not_null NOT NULL,
    last_schedule_version bigint DEFAULT 0 CONSTRAINT ticketing_scanner_device_assignm_last_schedule_version_not_null NOT NULL,
    last_admission_use_reversal_version bigint DEFAULT 0 CONSTRAINT ticketing_scanner_device_as_last_admission_use_reversa_not_null NOT NULL,
    last_synced_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_scanner_device_assignments_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'suspended'::character varying, 'revoked'::character varying, 'expired'::character varying])::text[]))),
    CONSTRAINT ticketing_scanner_device_assignments_versions_check CHECK (((last_revocation_version >= 0) AND (last_attendee_index_version >= 0) AND (last_schedule_version >= 0) AND (last_admission_use_reversal_version >= 0))),
    CONSTRAINT ticketing_scanner_device_assignments_window_check CHECK (((ends_at IS NULL) OR (starts_at IS NULL) OR (ends_at > starts_at)))
);


--
-- Name: ticketing_scanner_devices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_scanner_devices (
    id uuid DEFAULT uuidv7() NOT NULL,
    organization_id uuid NOT NULL,
    device_identifier character varying NOT NULL,
    name character varying,
    token_digest character varying(64) NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    last_seen_at timestamp with time zone,
    revoked_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_scanner_devices_identifier_check CHECK ((btrim((device_identifier)::text) <> ''::text)),
    CONSTRAINT ticketing_scanner_devices_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'suspended'::character varying, 'revoked'::character varying])::text[]))),
    CONSTRAINT ticketing_scanner_devices_token_digest_check CHECK (((token_digest)::text ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: ticketing_ticket_suspensions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_ticket_suspensions (
    id uuid DEFAULT uuidv7() NOT NULL,
    ticket_id uuid NOT NULL,
    event_id uuid NOT NULL,
    initiated_by_id uuid NOT NULL,
    reason_code character varying NOT NULL,
    internal_note_ciphertext text,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    review_deadline_at timestamp with time zone NOT NULL,
    resolved_by_id uuid,
    resolution_reason character varying,
    resolved_at timestamp with time zone,
    idempotency_key character varying NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_ticket_suspensions_reason_code_check CHECK (((reason_code)::text = ANY ((ARRAY['suspected_fraud'::character varying, 'identity_review'::character varying, 'chargeback_review'::character varying, 'safety_review'::character varying])::text[]))),
    CONSTRAINT ticketing_ticket_suspensions_resolution_reason_check CHECK (((resolution_reason IS NULL) OR ((resolution_reason)::text = ANY ((ARRAY['review_cleared'::character varying, 'organizer_cancellation'::character varying, 'refund_succeeded'::character varying, 'review_deadline_expired'::character varying])::text[])))),
    CONSTRAINT ticketing_ticket_suspensions_resolution_shape_check CHECK (((((status)::text = 'active'::text) AND (resolved_by_id IS NULL) AND (resolution_reason IS NULL) AND (resolved_at IS NULL)) OR (((status)::text <> 'active'::text) AND (resolved_by_id IS NOT NULL) AND (resolution_reason IS NOT NULL) AND (resolved_at IS NOT NULL)))),
    CONSTRAINT ticketing_ticket_suspensions_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'restored'::character varying, 'revoked_free'::character varying, 'cancelled_refunded'::character varying, 'expired'::character varying])::text[])))
);


--
-- Name: ticketing_ticket_transfers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_ticket_transfers (
    id uuid DEFAULT uuidv7() NOT NULL,
    ticket_id uuid NOT NULL,
    from_user_id uuid NOT NULL,
    to_user_id uuid NOT NULL,
    initiated_by_id uuid NOT NULL,
    token_digest character varying(64) NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    previous_version integer NOT NULL,
    new_version integer,
    reason character varying,
    expires_at timestamp with time zone NOT NULL,
    accepted_at timestamp with time zone,
    declined_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_ticket_transfers_acceptance_check CHECK (((((status)::text = 'accepted'::text) AND (new_version IS NOT NULL) AND (accepted_at IS NOT NULL)) OR (((status)::text <> 'accepted'::text) AND (new_version IS NULL) AND (accepted_at IS NULL)))),
    CONSTRAINT ticketing_ticket_transfers_cancellation_check CHECK (((((status)::text = 'cancelled'::text) AND (cancelled_at IS NOT NULL)) OR (((status)::text <> 'cancelled'::text) AND (cancelled_at IS NULL)))),
    CONSTRAINT ticketing_ticket_transfers_decline_check CHECK (((((status)::text = 'declined'::text) AND (declined_at IS NOT NULL)) OR (((status)::text <> 'declined'::text) AND (declined_at IS NULL)))),
    CONSTRAINT ticketing_ticket_transfers_recipient_check CHECK ((from_user_id <> to_user_id)),
    CONSTRAINT ticketing_ticket_transfers_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'accepted'::character varying, 'declined'::character varying, 'cancelled'::character varying, 'expired'::character varying])::text[]))),
    CONSTRAINT ticketing_ticket_transfers_values_check CHECK ((((token_digest)::text ~ '^[0-9a-f]{64}$'::text) AND (previous_version > 0)))
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
-- Name: ticketing_tickets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticketing_tickets (
    id uuid DEFAULT uuidv7() NOT NULL,
    event_id uuid NOT NULL,
    event_product_id uuid NOT NULL,
    registration_id uuid,
    order_item_id uuid,
    unit_number integer NOT NULL,
    admissions_per_unit_snapshot smallint NOT NULL,
    owner_user_id uuid NOT NULL,
    current_acquisition_type character varying NOT NULL,
    current_acquisition_order_item_id uuid,
    current_acquisition_product_value_minor bigint DEFAULT 0 CONSTRAINT ticketing_tickets_current_acquisition_product_value_mi_not_null NOT NULL,
    current_acquisition_currency character varying(3) NOT NULL,
    completed_resale_count smallint DEFAULT 0 NOT NULL,
    credential_mode character varying DEFAULT 'group'::character varying NOT NULL,
    credential_version integer DEFAULT 1 NOT NULL,
    current_credential_generation_id uuid,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    issued_at timestamp with time zone NOT NULL,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ticketing_tickets_acquisition_source_check CHECK (((((current_acquisition_type)::text = ANY ((ARRAY['primary_purchase'::character varying, 'resale_purchase'::character varying])::text[])) AND (current_acquisition_order_item_id IS NOT NULL)) OR (((current_acquisition_type)::text = ANY ((ARRAY['free_registration'::character varying, 'free_transfer'::character varying, 'complimentary'::character varying])::text[])) AND (current_acquisition_order_item_id IS NULL)))),
    CONSTRAINT ticketing_tickets_acquisition_type_check CHECK (((current_acquisition_type)::text = ANY ((ARRAY['primary_purchase'::character varying, 'resale_purchase'::character varying, 'free_registration'::character varying, 'free_transfer'::character varying, 'complimentary'::character varying])::text[]))),
    CONSTRAINT ticketing_tickets_acquisition_value_check CHECK ((current_acquisition_product_value_minor >= 0)),
    CONSTRAINT ticketing_tickets_credential_mode_check CHECK (((credential_mode)::text = ANY ((ARRAY['group'::character varying, 'delegated'::character varying])::text[]))),
    CONSTRAINT ticketing_tickets_currency_check CHECK (((current_acquisition_currency)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT ticketing_tickets_positive_values_check CHECK (((unit_number > 0) AND (admissions_per_unit_snapshot > 0) AND (completed_resale_count >= 0) AND (credential_version > 0))),
    CONSTRAINT ticketing_tickets_source_check CHECK (((registration_id IS NOT NULL) OR (order_item_id IS NOT NULL))),
    CONSTRAINT ticketing_tickets_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'suspended'::character varying, 'refunded'::character varying, 'void'::character varying])::text[])))
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
-- Name: commercial_approvals commercial_approvals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_approvals
    ADD CONSTRAINT commercial_approvals_pkey PRIMARY KEY (id);


--
-- Name: commercial_assignments commercial_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_assignments
    ADD CONSTRAINT commercial_assignments_pkey PRIMARY KEY (id);


--
-- Name: commercial_event_payer_selections commercial_event_payer_selections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_event_payer_selections
    ADD CONSTRAINT commercial_event_payer_selections_pkey PRIMARY KEY (id);


--
-- Name: commercial_fee_amounts commercial_fee_amounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_amounts
    ADD CONSTRAINT commercial_fee_amounts_pkey PRIMARY KEY (id);


--
-- Name: commercial_fee_components commercial_fee_components_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_components
    ADD CONSTRAINT commercial_fee_components_pkey PRIMARY KEY (id);


--
-- Name: commercial_fee_schedule_versions commercial_fee_schedule_versions_authoritative_interval; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_schedule_versions
    ADD CONSTRAINT commercial_fee_schedule_versions_authoritative_interval EXCLUDE USING gist (fee_schedule_id WITH =, tstzrange(effective_from, COALESCE(effective_until, 'infinity'::timestamp with time zone), '[)'::text) WITH &&) WHERE ((((status)::text = 'active'::text) AND (effective_from IS NOT NULL)));


--
-- Name: commercial_fee_schedule_versions commercial_fee_schedule_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_schedule_versions
    ADD CONSTRAINT commercial_fee_schedule_versions_pkey PRIMARY KEY (id);


--
-- Name: commercial_fee_schedules commercial_fee_schedules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_schedules
    ADD CONSTRAINT commercial_fee_schedules_pkey PRIMARY KEY (id);


--
-- Name: commercial_fee_tiers commercial_fee_tiers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_tiers
    ADD CONSTRAINT commercial_fee_tiers_pkey PRIMARY KEY (id);


--
-- Name: commercial_program_entitlements commercial_program_entitlements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_program_entitlements
    ADD CONSTRAINT commercial_program_entitlements_pkey PRIMARY KEY (id);


--
-- Name: commercial_programs commercial_programs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_programs
    ADD CONSTRAINT commercial_programs_pkey PRIMARY KEY (id);


--
-- Name: commercial_simulations commercial_simulations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_simulations
    ADD CONSTRAINT commercial_simulations_pkey PRIMARY KEY (id);


--
-- Name: commercial_subsidy_budgets commercial_subsidy_budgets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_subsidy_budgets
    ADD CONSTRAINT commercial_subsidy_budgets_pkey PRIMARY KEY (id);


--
-- Name: commercial_subsidy_reservations commercial_subsidy_reservations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_subsidy_reservations
    ADD CONSTRAINT commercial_subsidy_reservations_pkey PRIMARY KEY (id);


--
-- Name: commercial_term_notices commercial_term_notices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_term_notices
    ADD CONSTRAINT commercial_term_notices_pkey PRIMARY KEY (id);


--
-- Name: commercial_volume_counters commercial_volume_counters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_volume_counters
    ADD CONSTRAINT commercial_volume_counters_pkey PRIMARY KEY (id);


--
-- Name: commercial_volume_usages commercial_volume_usages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_volume_usages
    ADD CONSTRAINT commercial_volume_usages_pkey PRIMARY KEY (id);


--
-- Name: core_audit_logs core_audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_audit_logs
    ADD CONSTRAINT core_audit_logs_pkey PRIMARY KEY (id);


--
-- Name: core_data_retention_holds core_data_retention_holds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_data_retention_holds
    ADD CONSTRAINT core_data_retention_holds_pkey PRIMARY KEY (id);


--
-- Name: core_data_retention_policies core_data_retention_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_data_retention_policies
    ADD CONSTRAINT core_data_retention_policies_pkey PRIMARY KEY (id);


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
-- Name: core_reauthentication_proofs core_reauthentication_proofs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_reauthentication_proofs
    ADD CONSTRAINT core_reauthentication_proofs_pkey PRIMARY KEY (id);


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
-- Name: orders_order_adjustments orders_order_adjustments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_order_adjustments
    ADD CONSTRAINT orders_order_adjustments_pkey PRIMARY KEY (id);


--
-- Name: orders_order_items orders_order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_order_items
    ADD CONSTRAINT orders_order_items_pkey PRIMARY KEY (id);


--
-- Name: orders_orders orders_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_orders
    ADD CONSTRAINT orders_orders_pkey PRIMARY KEY (id);


--
-- Name: orders_payment_events orders_payment_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_payment_events
    ADD CONSTRAINT orders_payment_events_pkey PRIMARY KEY (id);


--
-- Name: orders_payments orders_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_payments
    ADD CONSTRAINT orders_payments_pkey PRIMARY KEY (id);


--
-- Name: orders_promotion_redemptions orders_promotion_redemptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_promotion_redemptions
    ADD CONSTRAINT orders_promotion_redemptions_pkey PRIMARY KEY (id);


--
-- Name: orders_refunds orders_refunds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_refunds
    ADD CONSTRAINT orders_refunds_pkey PRIMARY KEY (id);


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
-- Name: ticketing_admission_slots ticketing_admission_slots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_admission_slots
    ADD CONSTRAINT ticketing_admission_slots_pkey PRIMARY KEY (id);


--
-- Name: ticketing_admission_use_reversals ticketing_admission_use_reversals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_admission_use_reversals
    ADD CONSTRAINT ticketing_admission_use_reversals_pkey PRIMARY KEY (id);


--
-- Name: ticketing_admission_uses ticketing_admission_uses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_admission_uses
    ADD CONSTRAINT ticketing_admission_uses_pkey PRIMARY KEY (id);


--
-- Name: ticketing_attendee_exports ticketing_attendee_exports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_attendee_exports
    ADD CONSTRAINT ticketing_attendee_exports_pkey PRIMARY KEY (id);


--
-- Name: ticketing_attendee_index_entries ticketing_attendee_index_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_attendee_index_entries
    ADD CONSTRAINT ticketing_attendee_index_entries_pkey PRIMARY KEY (id);


--
-- Name: ticketing_checkin_logs ticketing_checkin_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_checkin_logs
    ADD CONSTRAINT ticketing_checkin_logs_pkey PRIMARY KEY (id);


--
-- Name: ticketing_credential_claims ticketing_credential_claims_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_credential_claims
    ADD CONSTRAINT ticketing_credential_claims_pkey PRIMARY KEY (id);


--
-- Name: ticketing_credential_generations ticketing_credential_generations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_credential_generations
    ADD CONSTRAINT ticketing_credential_generations_pkey PRIMARY KEY (id);


--
-- Name: ticketing_credential_revocations ticketing_credential_revocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_credential_revocations
    ADD CONSTRAINT ticketing_credential_revocations_pkey PRIMARY KEY (id);


--
-- Name: ticketing_credentials ticketing_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_credentials
    ADD CONSTRAINT ticketing_credentials_pkey PRIMARY KEY (id);


--
-- Name: ticketing_invitations ticketing_invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_invitations
    ADD CONSTRAINT ticketing_invitations_pkey PRIMARY KEY (id);


--
-- Name: ticketing_purchase_limit_allocations ticketing_purchase_limit_allocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_purchase_limit_allocations
    ADD CONSTRAINT ticketing_purchase_limit_allocations_pkey PRIMARY KEY (id);


--
-- Name: ticketing_purchase_limit_overrides ticketing_purchase_limit_overrides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_purchase_limit_overrides
    ADD CONSTRAINT ticketing_purchase_limit_overrides_pkey PRIMARY KEY (id);


--
-- Name: ticketing_registration_answer_revisions ticketing_registration_answer_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_answer_revisions
    ADD CONSTRAINT ticketing_registration_answer_revisions_pkey PRIMARY KEY (id);


--
-- Name: ticketing_registration_answers ticketing_registration_answers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_answers
    ADD CONSTRAINT ticketing_registration_answers_pkey PRIMARY KEY (id);


--
-- Name: ticketing_registration_consent_requirements ticketing_registration_consent_requirements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_consent_requirements
    ADD CONSTRAINT ticketing_registration_consent_requirements_pkey PRIMARY KEY (id);


--
-- Name: ticketing_registration_consent_withdrawals ticketing_registration_consent_withdrawals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_consent_withdrawals
    ADD CONSTRAINT ticketing_registration_consent_withdrawals_pkey PRIMARY KEY (id);


--
-- Name: ticketing_registration_consents ticketing_registration_consents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_consents
    ADD CONSTRAINT ticketing_registration_consents_pkey PRIMARY KEY (id);


--
-- Name: ticketing_registration_form_submissions ticketing_registration_form_submissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_form_submissions
    ADD CONSTRAINT ticketing_registration_form_submissions_pkey PRIMARY KEY (id);


--
-- Name: ticketing_registration_form_versions ticketing_registration_form_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_form_versions
    ADD CONSTRAINT ticketing_registration_form_versions_pkey PRIMARY KEY (id);


--
-- Name: ticketing_registration_forms ticketing_registration_forms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_forms
    ADD CONSTRAINT ticketing_registration_forms_pkey PRIMARY KEY (id);


--
-- Name: ticketing_registration_questions ticketing_registration_questions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_questions
    ADD CONSTRAINT ticketing_registration_questions_pkey PRIMARY KEY (id);


--
-- Name: ticketing_registrations ticketing_registrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registrations
    ADD CONSTRAINT ticketing_registrations_pkey PRIMARY KEY (id);


--
-- Name: ticketing_revocations ticketing_revocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_revocations
    ADD CONSTRAINT ticketing_revocations_pkey PRIMARY KEY (id);


--
-- Name: ticketing_scan_uploads ticketing_scan_uploads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_scan_uploads
    ADD CONSTRAINT ticketing_scan_uploads_pkey PRIMARY KEY (id);


--
-- Name: ticketing_scanner_assignment_zones ticketing_scanner_assignment_zones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_scanner_assignment_zones
    ADD CONSTRAINT ticketing_scanner_assignment_zones_pkey PRIMARY KEY (id);


--
-- Name: ticketing_scanner_device_assignments ticketing_scanner_device_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_scanner_device_assignments
    ADD CONSTRAINT ticketing_scanner_device_assignments_pkey PRIMARY KEY (id);


--
-- Name: ticketing_scanner_devices ticketing_scanner_devices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_scanner_devices
    ADD CONSTRAINT ticketing_scanner_devices_pkey PRIMARY KEY (id);


--
-- Name: ticketing_ticket_suspensions ticketing_ticket_suspensions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_ticket_suspensions
    ADD CONSTRAINT ticketing_ticket_suspensions_pkey PRIMARY KEY (id);


--
-- Name: ticketing_ticket_transfers ticketing_ticket_transfers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_ticket_transfers
    ADD CONSTRAINT ticketing_ticket_transfers_pkey PRIMARY KEY (id);


--
-- Name: ticketing_ticket_types ticketing_ticket_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_ticket_types
    ADD CONSTRAINT ticketing_ticket_types_pkey PRIMARY KEY (id);


--
-- Name: ticketing_tickets ticketing_tickets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_tickets
    ADD CONSTRAINT ticketing_tickets_pkey PRIMARY KEY (id);


--
-- Name: idx_access_zones_on_product_and_zone; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_access_zones_on_product_and_zone ON public.catalog_product_access_zones USING btree (product_access_id, access_zone_id);


--
-- Name: idx_active_scanner_assignment; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_active_scanner_assignment ON public.ticketing_scanner_device_assignments USING btree (scanner_device_id, event_id) WHERE ((status)::text = 'active'::text);


--
-- Name: idx_catalog_event_products_on_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_catalog_event_products_on_idempotency_key ON public.catalog_event_products USING btree (idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: idx_catalog_event_products_on_idempotency_key_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_catalog_event_products_on_idempotency_key_digest ON public.catalog_event_products USING btree (event_id, idempotency_key_digest) WHERE (idempotency_key_digest IS NOT NULL);


--
-- Name: idx_commercial_approvals_on_target_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_commercial_approvals_on_target_time ON public.commercial_approvals USING btree (target_type, target_id, decided_at);


--
-- Name: idx_commercial_assignments_active_resolution; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_commercial_assignments_active_resolution ON public.commercial_assignments USING btree (organization_id, event_id, status, effective_from) INCLUDE (fee_schedule_version_id, program_id, effective_until) WHERE ((status)::text = ANY ((ARRAY['scheduled'::character varying, 'active'::character varying])::text[]));


--
-- Name: idx_commercial_assignments_on_event_status_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_commercial_assignments_on_event_status_start ON public.commercial_assignments USING btree (event_id, status, effective_from) WHERE (event_id IS NOT NULL);


--
-- Name: idx_commercial_assignments_on_org_status_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_commercial_assignments_on_org_status_start ON public.commercial_assignments USING btree (organization_id, status, effective_from);


--
-- Name: idx_commercial_entitlements_unique_program_organization; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_commercial_entitlements_unique_program_organization ON public.commercial_program_entitlements USING btree (program_id, organization_id);


--
-- Name: idx_commercial_programs_unique_schedule; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_commercial_programs_unique_schedule ON public.commercial_programs USING btree (fee_schedule_id);


--
-- Name: idx_commercial_simulations_on_version_digest_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_commercial_simulations_on_version_digest_time ON public.commercial_simulations USING btree (fee_schedule_version_id, definition_digest, run_at);


--
-- Name: idx_commercial_subsidy_budgets_assignment_component_currency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_commercial_subsidy_budgets_assignment_component_currency ON public.commercial_subsidy_budgets USING btree (assignment_id, fee_component_id, currency) WHERE (assignment_id IS NOT NULL);


--
-- Name: idx_commercial_subsidy_budgets_component_currency; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_commercial_subsidy_budgets_component_currency ON public.commercial_subsidy_budgets USING btree (fee_component_id, currency);


--
-- Name: idx_commercial_subsidy_budgets_program_component_currency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_commercial_subsidy_budgets_program_component_currency ON public.commercial_subsidy_budgets USING btree (program_id, fee_component_id, currency) WHERE (program_id IS NOT NULL);


--
-- Name: idx_commercial_term_notices_on_organization_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_commercial_term_notices_on_organization_status ON public.commercial_term_notices USING btree (organization_id, status, available_at);


--
-- Name: idx_commercial_term_notices_unique_delivery; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_commercial_term_notices_unique_delivery ON public.commercial_term_notices USING btree (organization_id, fee_schedule_version_id, delivery_method);


--
-- Name: idx_consent_requirements_admission_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_consent_requirements_admission_slot ON public.ticketing_registration_consent_requirements USING btree (admission_slot_id);


--
-- Name: idx_consent_requirements_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_consent_requirements_due ON public.ticketing_registration_consent_requirements USING btree (status, required_at);


--
-- Name: idx_consent_requirements_registration; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_consent_requirements_registration ON public.ticketing_registration_consent_requirements USING btree (registration_id);


--
-- Name: idx_consent_requirements_subject; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_consent_requirements_subject ON public.ticketing_registration_consent_requirements USING btree (subject_user_id);


--
-- Name: idx_consent_requirements_supersedes; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_consent_requirements_supersedes ON public.ticketing_registration_consent_requirements USING btree (supersedes_requirement_id);


--
-- Name: idx_consent_requirements_version; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_consent_requirements_version ON public.ticketing_registration_consent_requirements USING btree (consent_document_version_id);


--
-- Name: idx_consent_withdrawals_by_registration; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_consent_withdrawals_by_registration ON public.ticketing_registration_consent_withdrawals USING btree (registration_id, withdrawn_at);


--
-- Name: idx_consent_withdrawals_by_signer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_consent_withdrawals_by_signer ON public.ticketing_registration_consent_withdrawals USING btree (withdrawn_by_user_id, withdrawn_at);


--
-- Name: idx_core_retention_policies_one_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_core_retention_policies_one_active ON public.core_data_retention_policies USING btree (category, COALESCE(jurisdiction_code, ''::character varying)) WHERE ((status)::text = 'active'::text);


--
-- Name: idx_core_retention_policies_scope_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_core_retention_policies_scope_version ON public.core_data_retention_policies USING btree (category, COALESCE(jurisdiction_code, ''::character varying), version);


--
-- Name: idx_core_reviews_resource_context; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_core_reviews_resource_context ON public.core_reviews USING btree (reviewable_type, reviewable_id, context);


--
-- Name: idx_core_reviews_reviewer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_core_reviews_reviewer ON public.core_reviews USING btree (reviewed_by_type, reviewed_by_id);


--
-- Name: idx_current_buyer_consent_requirement; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_current_buyer_consent_requirement ON public.ticketing_registration_consent_requirements USING btree (registration_id, consent_document_version_id) WHERE (((acceptance_scope)::text = 'buyer'::text) AND ((status)::text = ANY ((ARRAY['pending'::character varying, 'accepted'::character varying])::text[])));


--
-- Name: idx_current_slot_consent_requirement; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_current_slot_consent_requirement ON public.ticketing_registration_consent_requirements USING btree (registration_id, consent_document_version_id, package_unit_number, admission_position) WHERE (((acceptance_scope)::text = 'admission_slot'::text) AND ((status)::text = ANY ((ARRAY['pending'::character varying, 'accepted'::character varying])::text[])));


--
-- Name: idx_date_allocations_on_product_and_date; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_date_allocations_on_product_and_date ON public.catalog_product_date_allocations USING btree (event_product_id, event_date_id);


--
-- Name: idx_event_payer_selections_on_actor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_payer_selections_on_actor ON public.commercial_event_payer_selections USING btree (selected_by_id);


--
-- Name: idx_event_payer_selections_on_event_component; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_event_payer_selections_on_event_component ON public.commercial_event_payer_selections USING btree (event_id, fee_component_id);


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
-- Name: idx_on_admission_slot_id_product_access_id_usage_nu_e291a18192; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_admission_slot_id_product_access_id_usage_nu_e291a18192 ON public.ticketing_admission_uses USING btree (admission_slot_id, product_access_id, usage_number);


--
-- Name: idx_on_aggregate_type_aggregate_id_occurred_at_dc800603ae; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_aggregate_type_aggregate_id_occurred_at_dc800603ae ON public.core_outbox_events USING btree (aggregate_type, aggregate_id, occurred_at);


--
-- Name: idx_on_assigned_user_id_assignment_status_027d423ff0; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_assigned_user_id_assignment_status_027d423ff0 ON public.ticketing_admission_slots USING btree (assigned_user_id, assignment_status);


--
-- Name: idx_on_category_jurisdiction_code_status_effective__957fab264b; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_category_jurisdiction_code_status_effective__957fab264b ON public.core_data_retention_policies USING btree (category, jurisdiction_code, status, effective_at);


--
-- Name: idx_on_checkin_log_id_admission_slot_id_ff8a25c365; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_checkin_log_id_admission_slot_id_ff8a25c365 ON public.ticketing_admission_uses USING btree (checkin_log_id, admission_slot_id);


--
-- Name: idx_on_component_type_product_type_sale_context_76dde5288d; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_component_type_product_type_sale_context_76dde5288d ON public.commercial_fee_components USING btree (component_type, product_type, sale_context);


--
-- Name: idx_on_consent_document_id_ticket_type_id_73d6f9f9f0; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_consent_document_id_ticket_type_id_73d6f9f9f0 ON public.events_consent_document_products USING btree (consent_document_id, ticket_type_id);


--
-- Name: idx_on_event_id_category_released_at_73cc832cb9; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_event_id_category_released_at_73cc832cb9 ON public.core_data_retention_holds USING btree (event_id, category, released_at);


--
-- Name: idx_on_event_id_index_version_b5781801d2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_event_id_index_version_b5781801d2 ON public.ticketing_attendee_index_entries USING btree (event_id, index_version);


--
-- Name: idx_on_event_id_lookup_code_13c6942e6c; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_event_id_lookup_code_13c6942e6c ON public.ticketing_attendee_index_entries USING btree (event_id, lookup_code);


--
-- Name: idx_on_event_id_organization_id_ee33770ea4; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_event_id_organization_id_ee33770ea4 ON public.events_event_organizations USING btree (event_id, organization_id);


--
-- Name: idx_on_event_id_reversal_version_5e553a2e87; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_event_id_reversal_version_5e553a2e87 ON public.ticketing_admission_use_reversals USING btree (event_id, reversal_version);


--
-- Name: idx_on_event_id_revocation_version_4b798feea0; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_event_id_revocation_version_4b798feea0 ON public.ticketing_credential_revocations USING btree (event_id, revocation_version);


--
-- Name: idx_on_event_id_status_29a4ce38db; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_event_id_status_29a4ce38db ON public.ticketing_scanner_device_assignments USING btree (event_id, status);


--
-- Name: idx_on_event_id_status_created_at_96db20f4f7; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_event_id_status_created_at_96db20f4f7 ON public.ticketing_registrations USING btree (event_id, status, created_at);


--
-- Name: idx_on_event_id_status_sort_order_542594280f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_event_id_status_sort_order_542594280f ON public.catalog_event_products USING btree (event_id, status, sort_order);


--
-- Name: idx_on_event_id_user_id_role_75273129b3; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_event_id_user_id_role_75273129b3 ON public.events_event_staff_assignments USING btree (event_id, user_id, role);


--
-- Name: idx_on_fee_schedule_id_status_ac4c487e1e; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_fee_schedule_id_status_ac4c487e1e ON public.commercial_fee_schedule_versions USING btree (fee_schedule_id, status);


--
-- Name: idx_on_metric_type_window_type_currency_34fcab8ed0; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_metric_type_window_type_currency_34fcab8ed0 ON public.commercial_fee_tiers USING btree (metric_type, window_type, currency);


--
-- Name: idx_on_organization_id_status_ab96da78ad; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_organization_id_status_ab96da78ad ON public.commercial_program_entitlements USING btree (organization_id, status);


--
-- Name: idx_on_product_access_id_used_at_5bb476d6c6; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_product_access_id_used_at_5bb476d6c6 ON public.ticketing_admission_uses USING btree (product_access_id, used_at);


--
-- Name: idx_on_provider_payment_method_sales_channel_curren_32a039d86d; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_provider_payment_method_sales_channel_curren_32a039d86d ON public.commercial_fee_components USING btree (provider, payment_method, sales_channel, currency);


--
-- Name: idx_on_published_at_available_at_id_30dbfe6ec6; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_published_at_available_at_id_30dbfe6ec6 ON public.core_outbox_events USING btree (published_at, available_at, id);


--
-- Name: idx_on_registration_answer_id_revised_at_ad59af8066; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_registration_answer_id_revised_at_ad59af8066 ON public.ticketing_registration_answer_revisions USING btree (registration_answer_id, revised_at);


--
-- Name: idx_on_registration_form_id_status_6425f53474; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_registration_form_id_status_6425f53474 ON public.ticketing_registration_form_versions USING btree (registration_form_id, status);


--
-- Name: idx_on_registration_form_version_id_6f595c3c6c; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_registration_form_version_id_6f595c3c6c ON public.ticketing_registration_form_submissions USING btree (registration_form_version_id);


--
-- Name: idx_on_registration_id_category_released_at_2a21aa5a70; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_registration_id_category_released_at_2a21aa5a70 ON public.core_data_retention_holds USING btree (registration_id, category, released_at);


--
-- Name: idx_on_retention_policy_id_retain_until_39a1821c75; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_retention_policy_id_retain_until_39a1821c75 ON public.ticketing_registration_answers USING btree (retention_policy_id, retain_until);


--
-- Name: idx_on_scanner_device_assignment_id_client_upload_i_dabaaa1f70; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_scanner_device_assignment_id_client_upload_i_dabaaa1f70 ON public.ticketing_scan_uploads USING btree (scanner_device_assignment_id, client_upload_id);


--
-- Name: idx_on_scanner_device_assignment_id_received_at_e3b2e0ce81; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_scanner_device_assignment_id_received_at_e3b2e0ce81 ON public.ticketing_scan_uploads USING btree (scanner_device_assignment_id, received_at);


--
-- Name: idx_on_status_effective_from_effective_until_ed4ab9d52f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_status_effective_from_effective_until_ed4ab9d52f ON public.commercial_fee_schedule_versions USING btree (status, effective_from, effective_until);


--
-- Name: idx_on_submitted_by_user_id_b8cd03fa99; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_submitted_by_user_id_b8cd03fa99 ON public.ticketing_registration_form_submissions USING btree (submitted_by_user_id);


--
-- Name: idx_on_ticket_id_event_date_id_result_50038ab9b3; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_ticket_id_event_date_id_result_50038ab9b3 ON public.ticketing_checkin_logs USING btree (ticket_id, event_date_id, result);


--
-- Name: idx_on_ticket_id_version_545ec11116; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_ticket_id_version_545ec11116 ON public.ticketing_credential_generations USING btree (ticket_id, version);


--
-- Name: idx_on_ticket_type_id_contact_digest_bd3fd90acf; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_ticket_type_id_contact_digest_bd3fd90acf ON public.ticketing_invitations USING btree (ticket_type_id, contact_digest);


--
-- Name: idx_on_ticket_type_id_identity_digest_6b56f9450e; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_ticket_type_id_identity_digest_6b56f9450e ON public.ticketing_registrations USING btree (ticket_type_id, identity_digest);


--
-- Name: idx_on_ticket_type_id_user_id_selected_event_date_i_7da88dda27; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_ticket_type_id_user_id_selected_event_date_i_7da88dda27 ON public.ticketing_registrations USING btree (ticket_type_id, user_id, selected_event_date_id);


--
-- Name: idx_on_user_id_category_released_at_516f0054eb; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_user_id_category_released_at_516f0054eb ON public.core_data_retention_holds USING btree (user_id, category, released_at);


--
-- Name: idx_one_accepted_payment_per_order; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_accepted_payment_per_order ON public.orders_payments USING btree (order_id) WHERE (accepted_at IS NOT NULL);


--
-- Name: idx_one_active_checkout_per_buyer_event; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_active_checkout_per_buyer_event ON public.orders_orders USING btree (buyer_user_id, event_id) WHERE ((status)::text = ANY ((ARRAY['draft'::character varying, 'pending_payment'::character varying])::text[]));


--
-- Name: idx_one_active_generation_per_ticket; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_active_generation_per_ticket ON public.ticketing_credential_generations USING btree (ticket_id) WHERE ((status)::text = 'active'::text);


--
-- Name: idx_one_active_subsidy_reservation_per_order_budget; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_active_subsidy_reservation_per_order_budget ON public.commercial_subsidy_reservations USING btree (subsidy_budget_id, order_id) WHERE ((status)::text = ANY ((ARRAY['held'::character varying, 'processing'::character varying])::text[]));


--
-- Name: idx_one_active_ticket_suspension; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_active_ticket_suspension ON public.ticketing_ticket_suspensions USING btree (ticket_id) WHERE ((status)::text = 'active'::text);


--
-- Name: idx_one_consent_acceptance_per_requirement; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_consent_acceptance_per_requirement ON public.ticketing_registration_consents USING btree (registration_consent_requirement_id);


--
-- Name: idx_one_current_payment_attempt; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_current_payment_attempt ON public.orders_payments USING btree (order_id) WHERE ((superseded_at IS NULL) AND ((status)::text = ANY ((ARRAY['created'::character varying, 'processing'::character varying])::text[])));


--
-- Name: idx_one_individual_credential_per_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_individual_credential_per_slot ON public.ticketing_credentials USING btree (credential_generation_id, admission_slot_id) WHERE ((type)::text = 'individual'::text);


--
-- Name: idx_one_order_item_per_registration; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_order_item_per_registration ON public.orders_order_items USING btree (registration_id) WHERE (registration_id IS NOT NULL);


--
-- Name: idx_one_order_item_per_resale_listing; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_order_item_per_resale_listing ON public.orders_order_items USING btree (resale_listing_id) WHERE (resale_listing_id IS NOT NULL);


--
-- Name: idx_one_owner_per_org; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_owner_per_org ON public.organizations_memberships USING btree (organization_id) WHERE ((role)::text = 'owner'::text);


--
-- Name: idx_one_package_credential_per_generation; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_package_credential_per_generation ON public.ticketing_credentials USING btree (credential_generation_id) WHERE ((type)::text = 'package'::text);


--
-- Name: idx_one_payment_reversal_per_payment; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_payment_reversal_per_payment ON public.orders_refunds USING btree (payment_id) WHERE ((type)::text = 'payment_reversal'::text);


--
-- Name: idx_one_pending_ticket_transfer; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_pending_ticket_transfer ON public.ticketing_ticket_transfers USING btree (ticket_id) WHERE ((status)::text = 'pending'::text);


--
-- Name: idx_one_promotion_redemption_per_order; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_promotion_redemption_per_order ON public.orders_promotion_redemptions USING btree (order_id);


--
-- Name: idx_one_withdrawal_per_registration_consent; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_withdrawal_per_registration_consent ON public.ticketing_registration_consent_withdrawals USING btree (registration_consent_id);


--
-- Name: idx_order_adjustments_on_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_adjustments_on_order ON public.orders_order_adjustments USING btree (order_id);


--
-- Name: idx_order_adjustments_on_order_item; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_adjustments_on_order_item ON public.orders_order_adjustments USING btree (order_item_id);


--
-- Name: idx_order_adjustments_on_order_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_adjustments_on_order_type ON public.orders_order_adjustments USING btree (order_id, type);


--
-- Name: idx_order_adjustments_on_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_adjustments_on_source ON public.orders_order_adjustments USING btree (source_type, source_id);


--
-- Name: idx_order_items_on_event_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_items_on_event_product ON public.orders_order_items USING btree (event_product_id);


--
-- Name: idx_order_items_on_id_and_order; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_order_items_on_id_and_order ON public.orders_order_items USING btree (id, order_id);


--
-- Name: idx_order_items_on_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_items_on_order ON public.orders_order_items USING btree (order_id);


--
-- Name: idx_order_items_on_order_fulfillment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_items_on_order_fulfillment ON public.orders_order_items USING btree (order_id, fulfillment_status);


--
-- Name: idx_orders_on_creation_request_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_orders_on_creation_request_digest ON public.orders_orders USING btree (creation_request_digest);


--
-- Name: idx_orders_on_event_status_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_orders_on_event_status_expiry ON public.orders_orders USING btree (event_id, status, expires_at);


--
-- Name: idx_orders_on_idempotency_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_orders_on_idempotency_digest ON public.orders_orders USING btree (idempotency_key_digest);


--
-- Name: idx_orders_on_replacement; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_orders_on_replacement ON public.orders_orders USING btree (replaces_order_id) WHERE (replaces_order_id IS NOT NULL);


--
-- Name: idx_org_memberships_on_user_and_org; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_org_memberships_on_user_and_org ON public.organizations_memberships USING btree (user_id, organization_id);


--
-- Name: idx_payment_events_on_payment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payment_events_on_payment ON public.orders_payment_events USING btree (payment_id);


--
-- Name: idx_payment_events_on_provider_event; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_payment_events_on_provider_event ON public.orders_payment_events USING btree (provider, provider_event_id);


--
-- Name: idx_payment_events_on_status_and_received; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payment_events_on_status_and_received ON public.orders_payment_events USING btree (status, received_at);


--
-- Name: idx_payments_on_order_and_attempt; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_payments_on_order_and_attempt ON public.orders_payments USING btree (order_id, attempt_number);


--
-- Name: idx_payments_on_provider_and_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_payments_on_provider_and_idempotency ON public.orders_payments USING btree (provider, idempotency_key);


--
-- Name: idx_payments_on_provider_and_reference; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_payments_on_provider_and_reference ON public.orders_payments USING btree (provider, provider_reference) WHERE (provider_reference IS NOT NULL);


--
-- Name: idx_payments_on_status_and_grace_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payments_on_status_and_grace_expiry ON public.orders_payments USING btree (status, settlement_grace_expires_at);


--
-- Name: idx_product_accesses_on_product_date_type; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_product_accesses_on_product_date_type ON public.catalog_product_accesses USING btree (event_product_id, event_date_id, type);


--
-- Name: idx_promotion_products_on_promotion_and_product; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_promotion_products_on_promotion_and_product ON public.catalog_promotion_products USING btree (promotion_id, event_product_id);


--
-- Name: idx_promotion_redemptions_on_code_status_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_promotion_redemptions_on_code_status_expiry ON public.orders_promotion_redemptions USING btree (promotion_code_id, status, expires_at);


--
-- Name: idx_promotion_redemptions_on_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_promotion_redemptions_on_idempotency ON public.orders_promotion_redemptions USING btree (idempotency_key);


--
-- Name: idx_promotion_redemptions_on_promotion_status_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_promotion_redemptions_on_promotion_status_expiry ON public.orders_promotion_redemptions USING btree (promotion_id, status, expires_at);


--
-- Name: idx_promotion_redemptions_on_promotion_user_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_promotion_redemptions_on_promotion_user_status ON public.orders_promotion_redemptions USING btree (promotion_id, user_id, status);


--
-- Name: idx_registration_answer_revisions_answer_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_registration_answer_revisions_answer_number ON public.ticketing_registration_answer_revisions USING btree (registration_answer_id, revision_number);


--
-- Name: idx_registration_answer_revisions_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_registration_answer_revisions_idempotency ON public.ticketing_registration_answer_revisions USING btree (idempotency_key_digest);


--
-- Name: idx_registration_answers_admission_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_registration_answers_admission_scope ON public.ticketing_registration_answers USING btree (registration_form_submission_id, registration_question_id, package_unit_number, admission_position) WHERE ((response_scope_snapshot)::text = 'admission_slot'::text);


--
-- Name: idx_registration_answers_registration_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_registration_answers_registration_scope ON public.ticketing_registration_answers USING btree (registration_form_submission_id, registration_question_id) WHERE ((response_scope_snapshot)::text = 'registration'::text);


--
-- Name: idx_registration_consents_by_registration; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_registration_consents_by_registration ON public.ticketing_registration_consents USING btree (registration_id, accepted_at);


--
-- Name: idx_registration_consents_by_signer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_registration_consents_by_signer ON public.ticketing_registration_consents USING btree (accepted_by_user_id, accepted_at);


--
-- Name: idx_registration_consents_retention_policy; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_registration_consents_retention_policy ON public.ticketing_registration_consents USING btree (retention_policy_id);


--
-- Name: idx_registration_form_versions_form_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_registration_form_versions_form_version ON public.ticketing_registration_form_versions USING btree (registration_form_id, version);


--
-- Name: idx_registration_form_versions_one_published; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_registration_form_versions_one_published ON public.ticketing_registration_form_versions USING btree (registration_form_id) WHERE ((status)::text = 'published'::text);


--
-- Name: idx_registration_forms_event_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_registration_forms_event_name ON public.ticketing_registration_forms USING btree (event_id, lower((name)::text)) WHERE (ticket_type_id IS NULL);


--
-- Name: idx_registration_forms_product_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_registration_forms_product_name ON public.ticketing_registration_forms USING btree (ticket_type_id, lower((name)::text)) WHERE (ticket_type_id IS NOT NULL);


--
-- Name: idx_registration_questions_version_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_registration_questions_version_key ON public.ticketing_registration_questions USING btree (registration_form_version_id, key);


--
-- Name: idx_registration_questions_version_position; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_registration_questions_version_position ON public.ticketing_registration_questions USING btree (registration_form_version_id, "position");


--
-- Name: idx_registration_submissions_registration_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_registration_submissions_registration_version ON public.ticketing_registration_form_submissions USING btree (registration_id, registration_form_version_id);


--
-- Name: idx_scanner_assignment_zones_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_scanner_assignment_zones_unique ON public.ticketing_scanner_assignment_zones USING btree (scanner_device_assignment_id, access_zone_id);


--
-- Name: idx_subsidy_reservations_on_budget; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_subsidy_reservations_on_budget ON public.commercial_subsidy_reservations USING btree (subsidy_budget_id);


--
-- Name: idx_subsidy_reservations_on_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_subsidy_reservations_on_idempotency ON public.commercial_subsidy_reservations USING btree (idempotency_key_digest);


--
-- Name: idx_subsidy_reservations_on_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_subsidy_reservations_on_order ON public.commercial_subsidy_reservations USING btree (order_id);


--
-- Name: idx_subsidy_reservations_on_status_and_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_subsidy_reservations_on_status_and_expiry ON public.commercial_subsidy_reservations USING btree (status, expires_at);


--
-- Name: idx_ticket_suspensions_review_deadline; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ticket_suspensions_review_deadline ON public.ticketing_ticket_suspensions USING btree (event_id, status, review_deadline_at);


--
-- Name: idx_ticketing_access_codes_on_ticket_type_and_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ticketing_access_codes_on_ticket_type_and_idempotency ON public.ticketing_access_codes USING btree (ticket_type_id, idempotency_key_digest) WHERE (idempotency_key_digest IS NOT NULL);


--
-- Name: idx_ticketing_credentials_event_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ticketing_credentials_event_lookup ON public.ticketing_credentials USING btree (event_id, lookup_code) WHERE (lookup_code IS NOT NULL);


--
-- Name: idx_ticketing_invitations_on_ticket_type_and_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ticketing_invitations_on_ticket_type_and_idempotency ON public.ticketing_invitations USING btree (ticket_type_id, idempotency_key_digest) WHERE (idempotency_key_digest IS NOT NULL);


--
-- Name: idx_ticketing_purchase_limit_allocations_count; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ticketing_purchase_limit_allocations_count ON public.ticketing_purchase_limit_allocations USING btree (ticket_type_id, scope_event_date_id, user_id, status, expires_at);


--
-- Name: idx_ticketing_purchase_limit_allocations_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ticketing_purchase_limit_allocations_idempotency ON public.ticketing_purchase_limit_allocations USING btree (idempotency_key);


--
-- Name: idx_ticketing_purchase_limit_allocations_registration_ticket; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ticketing_purchase_limit_allocations_registration_ticket ON public.ticketing_purchase_limit_allocations USING btree (registration_id, ticket_id) WHERE (ticket_id IS NOT NULL);


--
-- Name: idx_ticketing_purchase_limit_allocations_registration_unit; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ticketing_purchase_limit_allocations_registration_unit ON public.ticketing_purchase_limit_allocations USING btree (registration_id, unit_number);


--
-- Name: idx_ticketing_purchase_limit_overrides_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ticketing_purchase_limit_overrides_idempotency ON public.ticketing_purchase_limit_overrides USING btree (idempotency_key);


--
-- Name: idx_ticketing_purchase_limit_overrides_registration; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ticketing_purchase_limit_overrides_registration ON public.ticketing_purchase_limit_overrides USING btree (registration_id);


--
-- Name: idx_ticketing_registrations_active_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ticketing_registrations_active_identity ON public.ticketing_registrations USING btree (ticket_type_id, identity_digest, COALESCE(selected_event_date_id, '00000000-0000-0000-0000-000000000000'::uuid)) WHERE ((status)::text = ANY ((ARRAY['pending_payment'::character varying, 'pending_approval'::character varying, 'waitlisted'::character varying, 'offered'::character varying, 'confirmed'::character varying])::text[]));


--
-- Name: idx_ticketing_registrations_issuance_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ticketing_registrations_issuance_idempotency ON public.ticketing_registrations USING btree (issuance_idempotency_key) WHERE (issuance_idempotency_key IS NOT NULL);


--
-- Name: idx_ticketing_registrations_queue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ticketing_registrations_queue ON public.ticketing_registrations USING btree (ticket_type_id, selected_event_date_id, status, waitlisted_at, id);


--
-- Name: idx_ticketing_tickets_id_event; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ticketing_tickets_id_event ON public.ticketing_tickets USING btree (id, event_id);


--
-- Name: idx_ticketing_tickets_order_item_unit; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ticketing_tickets_order_item_unit ON public.ticketing_tickets USING btree (order_item_id, unit_number) WHERE (order_item_id IS NOT NULL);


--
-- Name: idx_ticketing_tickets_registration_unit; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ticketing_tickets_registration_unit ON public.ticketing_tickets USING btree (registration_id, unit_number) WHERE (registration_id IS NOT NULL);


--
-- Name: idx_unique_consent_withdrawal_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_unique_consent_withdrawal_idempotency ON public.ticketing_registration_consent_withdrawals USING btree (idempotency_key);


--
-- Name: idx_unique_legal_acceptance; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_unique_legal_acceptance ON public.legal_acceptances USING btree (subject_type, subject_id, legal_document_version_id);


--
-- Name: idx_unique_legal_acceptance_request_uuid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_unique_legal_acceptance_request_uuid ON public.legal_acceptances USING btree (request_uuid);


--
-- Name: idx_unique_registration_consent_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_unique_registration_consent_idempotency_key ON public.ticketing_registration_consents USING btree (idempotency_key_digest);


--
-- Name: idx_unique_registration_consent_request_uuid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_unique_registration_consent_request_uuid ON public.ticketing_registration_consents USING btree (request_uuid);


--
-- Name: idx_venue_capacity_reservations_on_group_and_date; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_venue_capacity_reservations_on_group_and_date ON public.catalog_venue_capacity_reservations USING btree (reservation_group_id, event_date_id);


--
-- Name: idx_venue_capacity_reservations_on_status_and_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_venue_capacity_reservations_on_status_and_expires ON public.catalog_venue_capacity_reservations USING btree (status, expires_at);


--
-- Name: idx_volume_counters_on_component; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_volume_counters_on_component ON public.commercial_volume_counters USING btree (fee_component_id);


--
-- Name: idx_volume_counters_on_dimension; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_volume_counters_on_dimension ON public.commercial_volume_counters USING btree (fee_component_id, organization_id, event_id, metric_type, window_type, currency, window_start_at, window_end_at) NULLS NOT DISTINCT;


--
-- Name: idx_volume_counters_on_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_volume_counters_on_scope ON public.commercial_volume_counters USING btree (organization_id, event_id, metric_type, window_type);


--
-- Name: idx_volume_counters_on_window; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_volume_counters_on_window ON public.commercial_volume_counters USING btree (window_type, window_start_at, window_end_at);


--
-- Name: idx_volume_usages_on_component_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_volume_usages_on_component_scope ON public.commercial_volume_usages USING btree (fee_component_id, organization_id);


--
-- Name: idx_volume_usages_on_dimension; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_volume_usages_on_dimension ON public.commercial_volume_usages USING btree (metric_type, window_type, window_start_at, window_end_at, currency);


--
-- Name: idx_volume_usages_on_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_volume_usages_on_order ON public.commercial_volume_usages USING btree (order_id);


--
-- Name: idx_volume_usages_on_order_dimension; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_volume_usages_on_order_dimension ON public.commercial_volume_usages USING btree (order_id, fee_component_id, metric_type, window_type, currency, window_start_at, window_end_at) NULLS NOT DISTINCT;


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
-- Name: index_commercial_approvals_on_idempotency_key_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_commercial_approvals_on_idempotency_key_digest ON public.commercial_approvals USING btree (idempotency_key_digest);


--
-- Name: index_commercial_assignments_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commercial_assignments_on_created_by_id ON public.commercial_assignments USING btree (created_by_id);


--
-- Name: index_commercial_assignments_on_fee_schedule_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commercial_assignments_on_fee_schedule_version_id ON public.commercial_assignments USING btree (fee_schedule_version_id);


--
-- Name: index_commercial_assignments_on_legal_acceptance_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commercial_assignments_on_legal_acceptance_id ON public.commercial_assignments USING btree (legal_acceptance_id);


--
-- Name: index_commercial_assignments_on_program_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commercial_assignments_on_program_id ON public.commercial_assignments USING btree (program_id);


--
-- Name: index_commercial_fee_amounts_on_component_and_currency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_commercial_fee_amounts_on_component_and_currency ON public.commercial_fee_amounts USING btree (fee_component_id, currency);


--
-- Name: index_commercial_fee_components_on_event_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commercial_fee_components_on_event_product_id ON public.commercial_fee_components USING btree (event_product_id);


--
-- Name: index_commercial_fee_components_on_fee_schedule_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commercial_fee_components_on_fee_schedule_version_id ON public.commercial_fee_components USING btree (fee_schedule_version_id);


--
-- Name: index_commercial_fee_schedules_on_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_commercial_fee_schedules_on_code ON public.commercial_fee_schedules USING btree (code);


--
-- Name: index_commercial_fee_schedules_on_schedule_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commercial_fee_schedules_on_schedule_type ON public.commercial_fee_schedules USING btree (schedule_type);


--
-- Name: index_commercial_fee_tiers_on_component_and_position; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_commercial_fee_tiers_on_component_and_position ON public.commercial_fee_tiers USING btree (fee_component_id, "position");


--
-- Name: index_commercial_fee_versions_on_schedule_and_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_commercial_fee_versions_on_schedule_and_version ON public.commercial_fee_schedule_versions USING btree (fee_schedule_id, version);


--
-- Name: index_commercial_program_entitlements_on_program_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commercial_program_entitlements_on_program_id_and_status ON public.commercial_program_entitlements USING btree (program_id, status);


--
-- Name: index_commercial_program_entitlements_on_reserved_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commercial_program_entitlements_on_reserved_event_id ON public.commercial_program_entitlements USING btree (reserved_event_id);


--
-- Name: index_commercial_programs_on_active_and_starts_at_and_ends_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commercial_programs_on_active_and_starts_at_and_ends_at ON public.commercial_programs USING btree (active, starts_at, ends_at);


--
-- Name: index_commercial_programs_on_program_type_and_enrollment_mode; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commercial_programs_on_program_type_and_enrollment_mode ON public.commercial_programs USING btree (program_type, enrollment_mode);


--
-- Name: index_commercial_simulations_on_assignment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commercial_simulations_on_assignment_id ON public.commercial_simulations USING btree (assignment_id);


--
-- Name: index_commercial_simulations_on_idempotency_key_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_commercial_simulations_on_idempotency_key_digest ON public.commercial_simulations USING btree (idempotency_key_digest);


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
-- Name: index_core_data_retention_holds_on_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_core_data_retention_holds_on_idempotency_key ON public.core_data_retention_holds USING btree (idempotency_key);


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
-- Name: index_core_reauthentication_proofs_on_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_core_reauthentication_proofs_on_token_digest ON public.core_reauthentication_proofs USING btree (token_digest);


--
-- Name: index_core_reauthentication_proofs_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_reauthentication_proofs_on_user_id ON public.core_reauthentication_proofs USING btree (user_id);


--
-- Name: index_core_reauthentication_proofs_on_user_purpose_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_core_reauthentication_proofs_on_user_purpose_expiry ON public.core_reauthentication_proofs USING btree (user_id, purpose, expires_at);


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
-- Name: index_orders_refunds_on_event_cancellation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_orders_refunds_on_event_cancellation_id ON public.orders_refunds USING btree (event_cancellation_id);


--
-- Name: index_orders_refunds_on_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_orders_refunds_on_idempotency_key ON public.orders_refunds USING btree (idempotency_key);


--
-- Name: index_orders_refunds_on_payment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_orders_refunds_on_payment_id ON public.orders_refunds USING btree (payment_id);


--
-- Name: index_orders_refunds_on_status_and_next_retry_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_orders_refunds_on_status_and_next_retry_at ON public.orders_refunds USING btree (status, next_retry_at);


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
-- Name: index_ticketing_admission_slots_on_ticket_id_and_position; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_admission_slots_on_ticket_id_and_position ON public.ticketing_admission_slots USING btree (ticket_id, "position");


--
-- Name: index_ticketing_admission_use_reversals_on_admission_use_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_admission_use_reversals_on_admission_use_id ON public.ticketing_admission_use_reversals USING btree (admission_use_id);


--
-- Name: index_ticketing_admission_use_reversals_on_reversal_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_admission_use_reversals_on_reversal_group_id ON public.ticketing_admission_use_reversals USING btree (reversal_group_id);


--
-- Name: index_ticketing_attendee_exports_on_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_attendee_exports_on_event_id ON public.ticketing_attendee_exports USING btree (event_id);


--
-- Name: index_ticketing_attendee_exports_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_attendee_exports_on_expires_at ON public.ticketing_attendee_exports USING btree (expires_at);


--
-- Name: index_ticketing_attendee_exports_on_idempotency_key_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_attendee_exports_on_idempotency_key_digest ON public.ticketing_attendee_exports USING btree (idempotency_key_digest);


--
-- Name: index_ticketing_attendee_exports_on_requested_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_attendee_exports_on_requested_by_id ON public.ticketing_attendee_exports USING btree (requested_by_id);


--
-- Name: index_ticketing_attendee_exports_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_attendee_exports_on_status ON public.ticketing_attendee_exports USING btree (status);


--
-- Name: index_ticketing_attendee_index_entries_on_credential_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_attendee_index_entries_on_credential_id ON public.ticketing_attendee_index_entries USING btree (credential_id);


--
-- Name: index_ticketing_attendee_index_entries_on_owner_phone_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_attendee_index_entries_on_owner_phone_hash ON public.ticketing_attendee_index_entries USING btree (owner_phone_hash);


--
-- Name: index_ticketing_attendee_index_entries_on_phone_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_attendee_index_entries_on_phone_hash ON public.ticketing_attendee_index_entries USING btree (phone_hash);


--
-- Name: index_ticketing_attendee_index_entries_on_ticket_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_attendee_index_entries_on_ticket_id ON public.ticketing_attendee_index_entries USING btree (ticket_id);


--
-- Name: index_ticketing_checkin_logs_on_client_scan_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_checkin_logs_on_client_scan_id ON public.ticketing_checkin_logs USING btree (client_scan_id);


--
-- Name: index_ticketing_checkin_logs_on_credential_id_and_received_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_checkin_logs_on_credential_id_and_received_at ON public.ticketing_checkin_logs USING btree (credential_id, received_at);


--
-- Name: index_ticketing_checkin_logs_on_event_date_id_and_received_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_checkin_logs_on_event_date_id_and_received_at ON public.ticketing_checkin_logs USING btree (event_date_id, received_at);


--
-- Name: index_ticketing_checkin_logs_on_overrides_checkin_log_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_checkin_logs_on_overrides_checkin_log_id ON public.ticketing_checkin_logs USING btree (overrides_checkin_log_id) WHERE (overrides_checkin_log_id IS NOT NULL);


--
-- Name: index_ticketing_credential_claims_on_credential_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_credential_claims_on_credential_id ON public.ticketing_credential_claims USING btree (credential_id);


--
-- Name: index_ticketing_credential_claims_on_status_and_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_credential_claims_on_status_and_expires_at ON public.ticketing_credential_claims USING btree (status, expires_at);


--
-- Name: index_ticketing_credential_claims_on_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_credential_claims_on_token_digest ON public.ticketing_credential_claims USING btree (token_digest);


--
-- Name: index_ticketing_credential_revocations_on_credential_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_credential_revocations_on_credential_id ON public.ticketing_credential_revocations USING btree (credential_id);


--
-- Name: index_ticketing_credentials_on_ticket_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_credentials_on_ticket_id_and_status ON public.ticketing_credentials USING btree (ticket_id, status);


--
-- Name: index_ticketing_invitations_on_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_invitations_on_token_digest ON public.ticketing_invitations USING btree (token_digest);


--
-- Name: index_ticketing_registration_answers_on_admission_slot_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_registration_answers_on_admission_slot_id ON public.ticketing_registration_answers USING btree (admission_slot_id);


--
-- Name: index_ticketing_registration_forms_on_event_id_and_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_registration_forms_on_event_id_and_active ON public.ticketing_registration_forms USING btree (event_id, active);


--
-- Name: index_ticketing_revocations_on_event_id_and_revocation_version; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_revocations_on_event_id_and_revocation_version ON public.ticketing_revocations USING btree (event_id, revocation_version);


--
-- Name: index_ticketing_revocations_on_ticket_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_revocations_on_ticket_id ON public.ticketing_revocations USING btree (ticket_id);


--
-- Name: index_ticketing_scanner_assignment_zones_on_access_zone_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_scanner_assignment_zones_on_access_zone_id ON public.ticketing_scanner_assignment_zones USING btree (access_zone_id);


--
-- Name: index_ticketing_scanner_devices_on_device_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_scanner_devices_on_device_identifier ON public.ticketing_scanner_devices USING btree (device_identifier);


--
-- Name: index_ticketing_scanner_devices_on_organization_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_scanner_devices_on_organization_id_and_status ON public.ticketing_scanner_devices USING btree (organization_id, status);


--
-- Name: index_ticketing_scanner_devices_on_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_scanner_devices_on_token_digest ON public.ticketing_scanner_devices USING btree (token_digest);


--
-- Name: index_ticketing_ticket_suspensions_on_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_ticket_suspensions_on_idempotency_key ON public.ticketing_ticket_suspensions USING btree (idempotency_key);


--
-- Name: index_ticketing_ticket_transfers_on_status_and_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_ticket_transfers_on_status_and_expires_at ON public.ticketing_ticket_transfers USING btree (status, expires_at);


--
-- Name: index_ticketing_ticket_transfers_on_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_ticket_transfers_on_token_digest ON public.ticketing_ticket_transfers USING btree (token_digest);


--
-- Name: index_ticketing_ticket_types_on_event_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_ticket_types_on_event_product_id ON public.ticketing_ticket_types USING btree (event_product_id);


--
-- Name: index_ticketing_tickets_on_current_credential_generation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ticketing_tickets_on_current_credential_generation_id ON public.ticketing_tickets USING btree (current_credential_generation_id);


--
-- Name: index_ticketing_tickets_on_event_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_tickets_on_event_id_and_status ON public.ticketing_tickets USING btree (event_id, status);


--
-- Name: index_ticketing_tickets_on_owner_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ticketing_tickets_on_owner_user_id ON public.ticketing_tickets USING btree (owner_user_id);


--
-- Name: commercial_approvals trg_commercial_approval_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_commercial_approval_append_only BEFORE DELETE OR UPDATE ON public.commercial_approvals FOR EACH ROW EXECUTE FUNCTION public.commercial_approval_append_only();


--
-- Name: commercial_event_payer_selections trg_commercial_event_payer_selection_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_commercial_event_payer_selection_integrity BEFORE INSERT OR UPDATE ON public.commercial_event_payer_selections FOR EACH ROW EXECUTE FUNCTION public.commercial_event_payer_selection_integrity();


--
-- Name: commercial_fee_amounts trg_commercial_fee_amount_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_commercial_fee_amount_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.commercial_fee_amounts FOR EACH ROW EXECUTE FUNCTION public.commercial_fee_amount_immutable();


--
-- Name: commercial_fee_components trg_commercial_fee_component_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_commercial_fee_component_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.commercial_fee_components FOR EACH ROW EXECUTE FUNCTION public.commercial_fee_component_immutable();


--
-- Name: commercial_fee_schedule_versions trg_commercial_fee_schedule_version_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_commercial_fee_schedule_version_immutable BEFORE DELETE OR UPDATE ON public.commercial_fee_schedule_versions FOR EACH ROW EXECUTE FUNCTION public.commercial_fee_schedule_version_immutable();


--
-- Name: commercial_fee_tiers trg_commercial_fee_tier_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_commercial_fee_tier_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.commercial_fee_tiers FOR EACH ROW EXECUTE FUNCTION public.commercial_fee_tier_immutable();


--
-- Name: commercial_simulations trg_commercial_simulation_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_commercial_simulation_immutable BEFORE DELETE OR UPDATE ON public.commercial_simulations FOR EACH ROW EXECUTE FUNCTION public.commercial_simulation_immutable();


--
-- Name: commercial_subsidy_reservations trg_commercial_subsidy_reservation_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_commercial_subsidy_reservation_immutable BEFORE DELETE OR UPDATE ON public.commercial_subsidy_reservations FOR EACH ROW EXECUTE FUNCTION public.commercial_subsidy_reservation_immutable();


--
-- Name: commercial_volume_counters trg_commercial_volume_counter_scope; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_commercial_volume_counter_scope BEFORE INSERT OR UPDATE ON public.commercial_volume_counters FOR EACH ROW EXECUTE FUNCTION public.commercial_volume_counter_scope();


--
-- Name: commercial_volume_usages trg_commercial_volume_usage_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_commercial_volume_usage_integrity BEFORE INSERT OR DELETE OR UPDATE ON public.commercial_volume_usages FOR EACH ROW EXECUTE FUNCTION public.commercial_volume_usage_integrity();


--
-- Name: events_consent_document_versions trg_consent_version_locked; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_consent_version_locked BEFORE UPDATE ON public.events_consent_document_versions FOR EACH ROW EXECUTE FUNCTION public.lock_consent_version_on_update();


--
-- Name: events_consent_document_versions trg_consent_version_nodelete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_consent_version_nodelete BEFORE DELETE ON public.events_consent_document_versions FOR EACH ROW EXECUTE FUNCTION public.consent_version_delete_guard();


--
-- Name: core_data_retention_policies trg_core_retention_policy_active_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_retention_policy_active_insert BEFORE INSERT ON public.core_data_retention_policies FOR EACH ROW EXECUTE FUNCTION public.core_retention_policy_active_insert_guard();


--
-- Name: core_data_retention_policies trg_core_retention_policy_locked; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_retention_policy_locked BEFORE UPDATE ON public.core_data_retention_policies FOR EACH ROW EXECUTE FUNCTION public.core_retention_policy_immutable();


--
-- Name: core_data_retention_policies trg_core_retention_policy_nodelete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_retention_policy_nodelete BEFORE DELETE ON public.core_data_retention_policies FOR EACH ROW EXECUTE FUNCTION public.core_retention_policy_delete_guard();


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
-- Name: orders_order_adjustments trg_orders_order_adjustment_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_orders_order_adjustment_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.orders_order_adjustments FOR EACH ROW EXECUTE FUNCTION public.orders_order_adjustment_immutable();


--
-- Name: orders_order_adjustments trg_orders_order_adjustment_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_orders_order_adjustment_integrity BEFORE INSERT OR UPDATE ON public.orders_order_adjustments FOR EACH ROW EXECUTE FUNCTION public.orders_order_adjustment_integrity();


--
-- Name: orders_orders trg_orders_order_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_orders_order_immutable BEFORE DELETE OR UPDATE ON public.orders_orders FOR EACH ROW EXECUTE FUNCTION public.orders_order_immutable();


--
-- Name: orders_order_items trg_orders_order_item_event_scope; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_orders_order_item_event_scope BEFORE INSERT OR UPDATE ON public.orders_order_items FOR EACH ROW EXECUTE FUNCTION public.orders_order_item_event_scope();


--
-- Name: orders_order_items trg_orders_order_item_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_orders_order_item_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.orders_order_items FOR EACH ROW EXECUTE FUNCTION public.orders_order_item_immutable();


--
-- Name: orders_payments trg_orders_payment_snapshot_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_orders_payment_snapshot_integrity BEFORE INSERT OR UPDATE ON public.orders_payments FOR EACH ROW EXECUTE FUNCTION public.orders_payment_snapshot_integrity();


--
-- Name: orders_promotion_redemptions trg_orders_promotion_redemption_scope; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_orders_promotion_redemption_scope BEFORE INSERT OR UPDATE ON public.orders_promotion_redemptions FOR EACH ROW EXECUTE FUNCTION public.orders_promotion_redemption_scope();


--
-- Name: orders_refunds trg_orders_refund_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_orders_refund_integrity BEFORE INSERT OR UPDATE ON public.orders_refunds FOR EACH ROW EXECUTE FUNCTION public.orders_refund_integrity();


--
-- Name: ticketing_registration_answers trg_registration_answer_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_registration_answer_append_only BEFORE UPDATE ON public.ticketing_registration_answers FOR EACH ROW EXECUTE FUNCTION public.registration_answer_append_only();


--
-- Name: ticketing_registration_answers trg_registration_answer_nodelete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_registration_answer_nodelete BEFORE DELETE ON public.ticketing_registration_answers FOR EACH ROW EXECUTE FUNCTION public.registration_answer_delete_guard();


--
-- Name: ticketing_registration_answer_revisions trg_registration_answer_revision_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_registration_answer_revision_append_only BEFORE UPDATE ON public.ticketing_registration_answer_revisions FOR EACH ROW EXECUTE FUNCTION public.registration_answer_revision_append_only();


--
-- Name: ticketing_registration_answer_revisions trg_registration_answer_revision_nodelete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_registration_answer_revision_nodelete BEFORE DELETE ON public.ticketing_registration_answer_revisions FOR EACH ROW EXECUTE FUNCTION public.registration_answer_revision_delete_guard();


--
-- Name: ticketing_registration_answer_revisions trg_registration_answer_revision_sequence; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_registration_answer_revision_sequence BEFORE INSERT ON public.ticketing_registration_answer_revisions FOR EACH ROW EXECUTE FUNCTION public.registration_answer_revision_sequence();


--
-- Name: ticketing_registration_form_versions trg_registration_form_version_locked; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_registration_form_version_locked BEFORE UPDATE ON public.ticketing_registration_form_versions FOR EACH ROW EXECUTE FUNCTION public.registration_form_version_immutable();


--
-- Name: ticketing_registration_form_versions trg_registration_form_version_nodelete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_registration_form_version_nodelete BEFORE DELETE ON public.ticketing_registration_form_versions FOR EACH ROW EXECUTE FUNCTION public.registration_form_version_delete_guard();


--
-- Name: ticketing_registration_questions trg_registration_question_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_registration_question_insert BEFORE INSERT ON public.ticketing_registration_questions FOR EACH ROW EXECUTE FUNCTION public.registration_question_insert_guard();


--
-- Name: ticketing_registration_questions trg_registration_question_locked; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_registration_question_locked BEFORE UPDATE ON public.ticketing_registration_questions FOR EACH ROW EXECUTE FUNCTION public.registration_question_immutable();


--
-- Name: ticketing_registration_questions trg_registration_question_nodelete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_registration_question_nodelete BEFORE DELETE ON public.ticketing_registration_questions FOR EACH ROW EXECUTE FUNCTION public.registration_question_delete_guard();


--
-- Name: ticketing_registrations trg_registration_source_locked; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_registration_source_locked BEFORE UPDATE ON public.ticketing_registrations FOR EACH ROW EXECUTE FUNCTION public.registration_source_immutable();


--
-- Name: ticketing_admission_slots trg_ticketing_admission_slot_shape_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_admission_slot_shape_guard BEFORE INSERT OR UPDATE ON public.ticketing_admission_slots FOR EACH ROW EXECUTE FUNCTION public.ticketing_admission_slot_shape_guard();


--
-- Name: ticketing_admission_uses trg_ticketing_admission_use_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_admission_use_append_only BEFORE DELETE OR UPDATE ON public.ticketing_admission_uses FOR EACH ROW EXECUTE FUNCTION public.ticketing_admission_use_append_only();


--
-- Name: ticketing_admission_uses trg_ticketing_admission_use_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_ticketing_admission_use_integrity AFTER INSERT OR UPDATE ON public.ticketing_admission_uses DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.ticketing_admission_use_integrity();


--
-- Name: ticketing_admission_use_reversals trg_ticketing_admission_use_reversal_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_admission_use_reversal_append_only BEFORE DELETE OR UPDATE ON public.ticketing_admission_use_reversals FOR EACH ROW EXECUTE FUNCTION public.ticketing_admission_use_reversal_append_only();


--
-- Name: ticketing_admission_use_reversals trg_ticketing_admission_use_reversal_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_ticketing_admission_use_reversal_integrity AFTER INSERT OR UPDATE ON public.ticketing_admission_use_reversals DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.ticketing_admission_use_reversal_integrity();


--
-- Name: ticketing_checkin_logs trg_ticketing_checkin_log_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_checkin_log_append_only BEFORE DELETE OR UPDATE ON public.ticketing_checkin_logs FOR EACH ROW EXECUTE FUNCTION public.ticketing_checkin_log_append_only();


--
-- Name: ticketing_checkin_logs trg_ticketing_checkin_log_scope; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_checkin_log_scope BEFORE INSERT OR UPDATE ON public.ticketing_checkin_logs FOR EACH ROW EXECUTE FUNCTION public.ticketing_checkin_log_scope();


--
-- Name: ticketing_credentials trg_ticketing_credential_generation_cardinality; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_ticketing_credential_generation_cardinality AFTER INSERT OR DELETE OR UPDATE ON public.ticketing_credentials DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.ticketing_credential_generation_cardinality_guard();


--
-- Name: ticketing_credentials trg_ticketing_credential_shape_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_credential_shape_guard BEFORE INSERT OR UPDATE ON public.ticketing_credentials FOR EACH ROW EXECUTE FUNCTION public.ticketing_credential_shape_guard();


--
-- Name: ticketing_registration_answers trg_ticketing_registration_answer_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_registration_answer_integrity BEFORE INSERT OR UPDATE ON public.ticketing_registration_answers FOR EACH ROW EXECUTE FUNCTION public.ticketing_registration_answer_integrity_guard();


--
-- Name: ticketing_registration_answer_revisions trg_ticketing_registration_answer_revision_retention; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_registration_answer_revision_retention BEFORE INSERT OR UPDATE ON public.ticketing_registration_answer_revisions FOR EACH ROW EXECUTE FUNCTION public.ticketing_registration_answer_revision_retention_guard();


--
-- Name: ticketing_registration_consents trg_ticketing_registration_consent_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_registration_consent_integrity BEFORE INSERT ON public.ticketing_registration_consents FOR EACH ROW EXECUTE FUNCTION public.ticketing_registration_consent_integrity();


--
-- Name: ticketing_registration_consents trg_ticketing_registration_consent_locked; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_registration_consent_locked BEFORE DELETE OR UPDATE ON public.ticketing_registration_consents FOR EACH ROW EXECUTE FUNCTION public.ticketing_registration_consent_append_only();


--
-- Name: ticketing_registration_consent_requirements trg_ticketing_registration_consent_requirement_acceptance_evide; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_registration_consent_requirement_acceptance_evide BEFORE UPDATE OF status ON public.ticketing_registration_consent_requirements FOR EACH ROW EXECUTE FUNCTION public.ticketing_registration_consent_requirement_acceptance_evidence();


--
-- Name: ticketing_registration_consent_requirements trg_ticketing_registration_consent_requirement_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_registration_consent_requirement_integrity BEFORE INSERT OR UPDATE ON public.ticketing_registration_consent_requirements FOR EACH ROW EXECUTE FUNCTION public.ticketing_registration_consent_requirement_integrity();


--
-- Name: ticketing_registration_consent_requirements trg_ticketing_registration_consent_requirement_withdrawal_evide; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_registration_consent_requirement_withdrawal_evide BEFORE UPDATE OF status ON public.ticketing_registration_consent_requirements FOR EACH ROW EXECUTE FUNCTION public.ticketing_registration_consent_requirement_withdrawal_evidence();


--
-- Name: ticketing_registration_consent_withdrawals trg_ticketing_registration_consent_withdrawal_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_registration_consent_withdrawal_integrity BEFORE INSERT ON public.ticketing_registration_consent_withdrawals FOR EACH ROW EXECUTE FUNCTION public.ticketing_registration_consent_withdrawal_integrity();


--
-- Name: ticketing_registration_consent_withdrawals trg_ticketing_registration_consent_withdrawal_locked; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_registration_consent_withdrawal_locked BEFORE DELETE OR UPDATE ON public.ticketing_registration_consent_withdrawals FOR EACH ROW EXECUTE FUNCTION public.ticketing_registration_consent_withdrawal_append_only();


--
-- Name: ticketing_registration_forms trg_ticketing_registration_form_scope; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_registration_form_scope BEFORE INSERT OR UPDATE ON public.ticketing_registration_forms FOR EACH ROW EXECUTE FUNCTION public.ticketing_registration_form_scope_guard();


--
-- Name: ticketing_registrations trg_ticketing_registration_same_event; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_registration_same_event BEFORE INSERT OR UPDATE ON public.ticketing_registrations FOR EACH ROW EXECUTE FUNCTION public.ticketing_registration_same_event_guard();


--
-- Name: ticketing_registration_form_submissions trg_ticketing_registration_submission_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_registration_submission_immutable BEFORE DELETE OR UPDATE ON public.ticketing_registration_form_submissions FOR EACH ROW EXECUTE FUNCTION public.ticketing_registration_submission_immutable();


--
-- Name: ticketing_registration_form_submissions trg_ticketing_registration_submission_scope; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_registration_submission_scope BEFORE INSERT OR UPDATE ON public.ticketing_registration_form_submissions FOR EACH ROW EXECUTE FUNCTION public.ticketing_registration_submission_scope_guard();


--
-- Name: ticketing_scanner_assignment_zones trg_ticketing_scanner_assignment_zone_scope; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_scanner_assignment_zone_scope BEFORE INSERT OR UPDATE ON public.ticketing_scanner_assignment_zones FOR EACH ROW EXECUTE FUNCTION public.ticketing_scanner_assignment_zone_scope();


--
-- Name: ticketing_tickets trg_ticketing_ticket_scope_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ticketing_ticket_scope_guard BEFORE INSERT OR UPDATE ON public.ticketing_tickets FOR EACH ROW EXECUTE FUNCTION public.ticketing_ticket_scope_guard();


--
-- Name: catalog_inventory_reservations fk_catalog_inventory_reservations_registration; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_inventory_reservations
    ADD CONSTRAINT fk_catalog_inventory_reservations_registration FOREIGN KEY (registration_id) REFERENCES public.ticketing_registrations(id);


--
-- Name: catalog_venue_capacity_reservations fk_catalog_venue_capacity_reservations_registration; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_venue_capacity_reservations
    ADD CONSTRAINT fk_catalog_venue_capacity_reservations_registration FOREIGN KEY (registration_id) REFERENCES public.ticketing_registrations(id);


--
-- Name: orders_order_adjustments fk_order_adjustments_item_order; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_order_adjustments
    ADD CONSTRAINT fk_order_adjustments_item_order FOREIGN KEY (order_item_id, order_id) REFERENCES public.orders_order_items(id, order_id) ON DELETE RESTRICT;


--
-- Name: ticketing_admission_uses fk_rails_00b9e125c9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_admission_uses
    ADD CONSTRAINT fk_rails_00b9e125c9 FOREIGN KEY (credential_id) REFERENCES public.ticketing_credentials(id);


--
-- Name: ticketing_registration_answers fk_rails_017cdf08f2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_answers
    ADD CONSTRAINT fk_rails_017cdf08f2 FOREIGN KEY (registration_form_submission_id) REFERENCES public.ticketing_registration_form_submissions(id);


--
-- Name: commercial_assignments fk_rails_024692f7fd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_assignments
    ADD CONSTRAINT fk_rails_024692f7fd FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE RESTRICT;


--
-- Name: orders_promotion_redemptions fk_rails_0261d89a8a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_promotion_redemptions
    ADD CONSTRAINT fk_rails_0261d89a8a FOREIGN KEY (promotion_code_id) REFERENCES public.catalog_promotion_codes(id) ON DELETE RESTRICT;


--
-- Name: orders_refunds fk_rails_028cc1b359; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_refunds
    ADD CONSTRAINT fk_rails_028cc1b359 FOREIGN KEY (payment_id) REFERENCES public.orders_payments(id) ON DELETE RESTRICT;


--
-- Name: ticketing_purchase_limit_overrides fk_rails_02b34260ba; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_purchase_limit_overrides
    ADD CONSTRAINT fk_rails_02b34260ba FOREIGN KEY (ticket_type_id) REFERENCES public.ticketing_ticket_types(id);


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
-- Name: commercial_assignments fk_rails_03fbf2b83b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_assignments
    ADD CONSTRAINT fk_rails_03fbf2b83b FOREIGN KEY (created_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: catalog_product_date_allocations fk_rails_0586ee8b97; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_date_allocations
    ADD CONSTRAINT fk_rails_0586ee8b97 FOREIGN KEY (event_date_id) REFERENCES public.events_event_dates(id);


--
-- Name: commercial_fee_amounts fk_rails_0770bb8e98; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_amounts
    ADD CONSTRAINT fk_rails_0770bb8e98 FOREIGN KEY (fee_component_id) REFERENCES public.commercial_fee_components(id) ON DELETE RESTRICT;


--
-- Name: commercial_program_entitlements fk_rails_077eb5c256; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_program_entitlements
    ADD CONSTRAINT fk_rails_077eb5c256 FOREIGN KEY (program_id) REFERENCES public.commercial_programs(id) ON DELETE RESTRICT;


--
-- Name: events_events fk_rails_08a9375b27; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_events
    ADD CONSTRAINT fk_rails_08a9375b27 FOREIGN KEY (organization_id) REFERENCES public.organizations_organizations(id) ON DELETE RESTRICT;


--
-- Name: ticketing_admission_slots fk_rails_08f57594b9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_admission_slots
    ADD CONSTRAINT fk_rails_08f57594b9 FOREIGN KEY (ticket_id) REFERENCES public.ticketing_tickets(id);


--
-- Name: ticketing_credential_generations fk_rails_092fa3af60; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_credential_generations
    ADD CONSTRAINT fk_rails_092fa3af60 FOREIGN KEY (ticket_id) REFERENCES public.ticketing_tickets(id);


--
-- Name: orders_promotion_redemptions fk_rails_0a2f4400d9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_promotion_redemptions
    ADD CONSTRAINT fk_rails_0a2f4400d9 FOREIGN KEY (user_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: orders_payments fk_rails_0acd2d914e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_payments
    ADD CONSTRAINT fk_rails_0acd2d914e FOREIGN KEY (order_id) REFERENCES public.orders_orders(id) ON DELETE RESTRICT;


--
-- Name: organizations_memberships fk_rails_0becb5aad6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations_memberships
    ADD CONSTRAINT fk_rails_0becb5aad6 FOREIGN KEY (user_id) REFERENCES public.core_users(id);


--
-- Name: commercial_volume_counters fk_rails_0c206abbf1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_volume_counters
    ADD CONSTRAINT fk_rails_0c206abbf1 FOREIGN KEY (fee_component_id) REFERENCES public.commercial_fee_components(id) ON DELETE RESTRICT;


--
-- Name: commercial_fee_schedule_versions fk_rails_0d8d1d857e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_schedule_versions
    ADD CONSTRAINT fk_rails_0d8d1d857e FOREIGN KEY (activated_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: ticketing_registrations fk_rails_0e3316ecf7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registrations
    ADD CONSTRAINT fk_rails_0e3316ecf7 FOREIGN KEY (user_id) REFERENCES public.core_users(id);


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
-- Name: ticketing_tickets fk_rails_1181b2a3a4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_tickets
    ADD CONSTRAINT fk_rails_1181b2a3a4 FOREIGN KEY (current_acquisition_order_item_id) REFERENCES public.orders_order_items(id);


--
-- Name: commercial_subsidy_budgets fk_rails_11847a9288; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_subsidy_budgets
    ADD CONSTRAINT fk_rails_11847a9288 FOREIGN KEY (fee_component_id) REFERENCES public.commercial_fee_components(id) ON DELETE RESTRICT;


--
-- Name: commercial_subsidy_budgets fk_rails_1259a58993; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_subsidy_budgets
    ADD CONSTRAINT fk_rails_1259a58993 FOREIGN KEY (assignment_id) REFERENCES public.commercial_assignments(id) ON DELETE RESTRICT;


--
-- Name: commercial_term_notices fk_rails_13717644e2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_term_notices
    ADD CONSTRAINT fk_rails_13717644e2 FOREIGN KEY (legal_document_version_id) REFERENCES public.legal_document_versions(id) ON DELETE RESTRICT;


--
-- Name: commercial_assignments fk_rails_13a045aabd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_assignments
    ADD CONSTRAINT fk_rails_13a045aabd FOREIGN KEY (terminated_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: ticketing_purchase_limit_allocations fk_rails_150f196df3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_purchase_limit_allocations
    ADD CONSTRAINT fk_rails_150f196df3 FOREIGN KEY (registration_id) REFERENCES public.ticketing_registrations(id);


--
-- Name: catalog_product_access_zones fk_rails_15800e5abf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_access_zones
    ADD CONSTRAINT fk_rails_15800e5abf FOREIGN KEY (access_zone_id) REFERENCES public.events_access_zones(id);


--
-- Name: ticketing_attendee_index_entries fk_rails_16fdbc2d17; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_attendee_index_entries
    ADD CONSTRAINT fk_rails_16fdbc2d17 FOREIGN KEY (ticket_id) REFERENCES public.ticketing_tickets(id);


--
-- Name: ticketing_admission_use_reversals fk_rails_17f424634b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_admission_use_reversals
    ADD CONSTRAINT fk_rails_17f424634b FOREIGN KEY (admission_use_id) REFERENCES public.ticketing_admission_uses(id);


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
-- Name: orders_payment_events fk_rails_1de614fb3c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_payment_events
    ADD CONSTRAINT fk_rails_1de614fb3c FOREIGN KEY (payment_id) REFERENCES public.orders_payments(id) ON DELETE RESTRICT;


--
-- Name: ticketing_tickets fk_rails_1ef2780902; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_tickets
    ADD CONSTRAINT fk_rails_1ef2780902 FOREIGN KEY (event_product_id) REFERENCES public.catalog_event_products(id);


--
-- Name: catalog_promotions fk_rails_1f9d62eca8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_promotions
    ADD CONSTRAINT fk_rails_1f9d62eca8 FOREIGN KEY (event_id) REFERENCES public.events_events(id);


--
-- Name: ticketing_admission_use_reversals fk_rails_1fe67bbf01; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_admission_use_reversals
    ADD CONSTRAINT fk_rails_1fe67bbf01 FOREIGN KEY (checkin_log_id) REFERENCES public.ticketing_checkin_logs(id);


--
-- Name: ticketing_ticket_transfers fk_rails_20ad03f53d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_ticket_transfers
    ADD CONSTRAINT fk_rails_20ad03f53d FOREIGN KEY (to_user_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_scanner_device_assignments fk_rails_220ef5a8d9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_scanner_device_assignments
    ADD CONSTRAINT fk_rails_220ef5a8d9 FOREIGN KEY (scanner_device_id) REFERENCES public.ticketing_scanner_devices(id);


--
-- Name: commercial_program_entitlements fk_rails_22f7aea472; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_program_entitlements
    ADD CONSTRAINT fk_rails_22f7aea472 FOREIGN KEY (reserved_event_id) REFERENCES public.events_events(id) ON DELETE RESTRICT;


--
-- Name: orders_promotion_redemptions fk_rails_24be26217b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_promotion_redemptions
    ADD CONSTRAINT fk_rails_24be26217b FOREIGN KEY (order_id) REFERENCES public.orders_orders(id) ON DELETE RESTRICT;


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
-- Name: commercial_volume_usages fk_rails_2acca2a05d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_volume_usages
    ADD CONSTRAINT fk_rails_2acca2a05d FOREIGN KEY (organization_id) REFERENCES public.organizations_organizations(id) ON DELETE RESTRICT;


--
-- Name: commercial_assignments fk_rails_2b5d0d49b4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_assignments
    ADD CONSTRAINT fk_rails_2b5d0d49b4 FOREIGN KEY (program_id) REFERENCES public.commercial_programs(id) ON DELETE RESTRICT;


--
-- Name: orders_orders fk_rails_2b71d52eb7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_orders
    ADD CONSTRAINT fk_rails_2b71d52eb7 FOREIGN KEY (buyer_user_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: commercial_assignments fk_rails_2c9a2fcc51; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_assignments
    ADD CONSTRAINT fk_rails_2c9a2fcc51 FOREIGN KEY (external_accepted_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: ticketing_checkin_logs fk_rails_2d37b108ac; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_checkin_logs
    ADD CONSTRAINT fk_rails_2d37b108ac FOREIGN KEY (product_access_id) REFERENCES public.catalog_product_accesses(id);


--
-- Name: commercial_assignments fk_rails_2e1247f9a8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_assignments
    ADD CONSTRAINT fk_rails_2e1247f9a8 FOREIGN KEY (approved_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: catalog_venue_capacity_reservations fk_rails_2e6172ce0c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_venue_capacity_reservations
    ADD CONSTRAINT fk_rails_2e6172ce0c FOREIGN KEY (event_product_id) REFERENCES public.catalog_event_products(id);


--
-- Name: ticketing_registration_consent_requirements fk_rails_2e923d40cf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_consent_requirements
    ADD CONSTRAINT fk_rails_2e923d40cf FOREIGN KEY (required_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


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
-- Name: ticketing_registration_consents fk_rails_2fd38622e7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_consents
    ADD CONSTRAINT fk_rails_2fd38622e7 FOREIGN KEY (accepted_by_user_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: ticketing_registrations fk_rails_31b1d71371; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registrations
    ADD CONSTRAINT fk_rails_31b1d71371 FOREIGN KEY (reviewed_by_id) REFERENCES public.core_users(id);


--
-- Name: commercial_program_entitlements fk_rails_31d9bf3b08; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_program_entitlements
    ADD CONSTRAINT fk_rails_31d9bf3b08 FOREIGN KEY (organization_id) REFERENCES public.organizations_organizations(id) ON DELETE RESTRICT;


--
-- Name: ticketing_registrations fk_rails_31e8de71c0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registrations
    ADD CONSTRAINT fk_rails_31e8de71c0 FOREIGN KEY (selected_event_date_id) REFERENCES public.events_event_dates(id);


--
-- Name: core_data_retention_holds fk_rails_320f1e5fba; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_data_retention_holds
    ADD CONSTRAINT fk_rails_320f1e5fba FOREIGN KEY (registration_id) REFERENCES public.ticketing_registrations(id);


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
-- Name: ticketing_credentials fk_rails_35843446bb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_credentials
    ADD CONSTRAINT fk_rails_35843446bb FOREIGN KEY (event_id) REFERENCES public.events_events(id);


--
-- Name: core_data_retention_holds fk_rails_3662b882d2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_data_retention_holds
    ADD CONSTRAINT fk_rails_3662b882d2 FOREIGN KEY (event_id) REFERENCES public.events_events(id);


--
-- Name: ticketing_admission_uses fk_rails_388ca487e1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_admission_uses
    ADD CONSTRAINT fk_rails_388ca487e1 FOREIGN KEY (product_access_id) REFERENCES public.catalog_product_accesses(id);


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
-- Name: commercial_assignments fk_rails_3e6ba061e9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_assignments
    ADD CONSTRAINT fk_rails_3e6ba061e9 FOREIGN KEY (activated_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: orders_order_items fk_rails_3e9c5b1ba4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_order_items
    ADD CONSTRAINT fk_rails_3e9c5b1ba4 FOREIGN KEY (registration_id) REFERENCES public.ticketing_registrations(id) ON DELETE RESTRICT;


--
-- Name: core_refresh_tokens fk_rails_3ed4f2d68b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_refresh_tokens
    ADD CONSTRAINT fk_rails_3ed4f2d68b FOREIGN KEY (user_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_checkin_logs fk_rails_3ff8f81542; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_checkin_logs
    ADD CONSTRAINT fk_rails_3ff8f81542 FOREIGN KEY (access_zone_id) REFERENCES public.events_access_zones(id);


--
-- Name: orders_order_items fk_rails_407ab6b9a2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_order_items
    ADD CONSTRAINT fk_rails_407ab6b9a2 FOREIGN KEY (event_product_id) REFERENCES public.catalog_event_products(id) ON DELETE RESTRICT;


--
-- Name: commercial_volume_usages fk_rails_41dbf1e9c6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_volume_usages
    ADD CONSTRAINT fk_rails_41dbf1e9c6 FOREIGN KEY (fee_component_id) REFERENCES public.commercial_fee_components(id) ON DELETE RESTRICT;


--
-- Name: ticketing_purchase_limit_overrides fk_rails_41f5759f50; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_purchase_limit_overrides
    ADD CONSTRAINT fk_rails_41f5759f50 FOREIGN KEY (scope_event_date_id) REFERENCES public.events_event_dates(id);


--
-- Name: ticketing_registration_consent_requirements fk_rails_43273f1434; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_consent_requirements
    ADD CONSTRAINT fk_rails_43273f1434 FOREIGN KEY (subject_user_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: ticketing_access_codes fk_rails_46c5693101; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_access_codes
    ADD CONSTRAINT fk_rails_46c5693101 FOREIGN KEY (ticket_type_id) REFERENCES public.ticketing_ticket_types(id);


--
-- Name: ticketing_registration_answer_revisions fk_rails_48da8f5fe7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_answer_revisions
    ADD CONSTRAINT fk_rails_48da8f5fe7 FOREIGN KEY (revised_by_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_revocations fk_rails_492547aca2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_revocations
    ADD CONSTRAINT fk_rails_492547aca2 FOREIGN KEY (ticket_id) REFERENCES public.ticketing_tickets(id);


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
-- Name: ticketing_registrations fk_rails_4bd767e905; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registrations
    ADD CONSTRAINT fk_rails_4bd767e905 FOREIGN KEY (event_id) REFERENCES public.events_events(id);


--
-- Name: events_event_media fk_rails_4cfe9ee26b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_media
    ADD CONSTRAINT fk_rails_4cfe9ee26b FOREIGN KEY (created_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: commercial_fee_components fk_rails_5166110a32; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_components
    ADD CONSTRAINT fk_rails_5166110a32 FOREIGN KEY (event_product_id) REFERENCES public.catalog_event_products(id) ON DELETE RESTRICT;


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
-- Name: ticketing_registrations fk_rails_55788dc7bd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registrations
    ADD CONSTRAINT fk_rails_55788dc7bd FOREIGN KEY (created_by_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_attendee_index_entries fk_rails_55a4dd09ff; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_attendee_index_entries
    ADD CONSTRAINT fk_rails_55a4dd09ff FOREIGN KEY (event_id) REFERENCES public.events_events(id);


--
-- Name: orders_order_adjustments fk_rails_55e4c64d49; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_order_adjustments
    ADD CONSTRAINT fk_rails_55e4c64d49 FOREIGN KEY (order_id) REFERENCES public.orders_orders(id) ON DELETE RESTRICT;


--
-- Name: commercial_approvals fk_rails_55f27ddd51; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_approvals
    ADD CONSTRAINT fk_rails_55f27ddd51 FOREIGN KEY (actor_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: ticketing_registration_answers fk_rails_56b2f6051e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_answers
    ADD CONSTRAINT fk_rails_56b2f6051e FOREIGN KEY (registration_question_id) REFERENCES public.ticketing_registration_questions(id);


--
-- Name: catalog_promotions fk_rails_56d77862e4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_promotions
    ADD CONSTRAINT fk_rails_56d77862e4 FOREIGN KEY (supersedes_promotion_id) REFERENCES public.catalog_promotions(id);


--
-- Name: ticketing_registration_form_submissions fk_rails_586686e549; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_form_submissions
    ADD CONSTRAINT fk_rails_586686e549 FOREIGN KEY (registration_id) REFERENCES public.ticketing_registrations(id);


--
-- Name: core_data_retention_policies fk_rails_590ed696c0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_data_retention_policies
    ADD CONSTRAINT fk_rails_590ed696c0 FOREIGN KEY (created_by_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_invitations fk_rails_596dd5e6f4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_invitations
    ADD CONSTRAINT fk_rails_596dd5e6f4 FOREIGN KEY (created_by_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_tickets fk_rails_5a58e723cb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_tickets
    ADD CONSTRAINT fk_rails_5a58e723cb FOREIGN KEY (owner_user_id) REFERENCES public.core_users(id);


--
-- Name: core_follows fk_rails_5acb788933; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_follows
    ADD CONSTRAINT fk_rails_5acb788933 FOREIGN KEY (follower_id) REFERENCES public.core_users(id);


--
-- Name: core_data_retention_holds fk_rails_5ae600f1b0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_data_retention_holds
    ADD CONSTRAINT fk_rails_5ae600f1b0 FOREIGN KEY (placed_by_id) REFERENCES public.core_users(id);


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
-- Name: ticketing_registration_questions fk_rails_605ad621df; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_questions
    ADD CONSTRAINT fk_rails_605ad621df FOREIGN KEY (registration_form_version_id) REFERENCES public.ticketing_registration_form_versions(id);


--
-- Name: commercial_term_notices fk_rails_613af43c5e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_term_notices
    ADD CONSTRAINT fk_rails_613af43c5e FOREIGN KEY (organization_id) REFERENCES public.organizations_organizations(id) ON DELETE RESTRICT;


--
-- Name: commercial_volume_counters fk_rails_61c11298e3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_volume_counters
    ADD CONSTRAINT fk_rails_61c11298e3 FOREIGN KEY (organization_id) REFERENCES public.organizations_organizations(id) ON DELETE RESTRICT;


--
-- Name: catalog_venue_capacity_reservations fk_rails_644ded3b72; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_venue_capacity_reservations
    ADD CONSTRAINT fk_rails_644ded3b72 FOREIGN KEY (event_date_id) REFERENCES public.events_event_dates(id);


--
-- Name: ticketing_checkin_logs fk_rails_6500fc4a55; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_checkin_logs
    ADD CONSTRAINT fk_rails_6500fc4a55 FOREIGN KEY (scan_upload_id) REFERENCES public.ticketing_scan_uploads(id);


--
-- Name: ticketing_tickets fk_rails_65628bf63c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_tickets
    ADD CONSTRAINT fk_rails_65628bf63c FOREIGN KEY (registration_id) REFERENCES public.ticketing_registrations(id);


--
-- Name: ticketing_registration_forms fk_rails_65c10bc3a2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_forms
    ADD CONSTRAINT fk_rails_65c10bc3a2 FOREIGN KEY (event_id) REFERENCES public.events_events(id);


--
-- Name: ticketing_scanner_device_assignments fk_rails_6636ae8d75; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_scanner_device_assignments
    ADD CONSTRAINT fk_rails_6636ae8d75 FOREIGN KEY (event_id) REFERENCES public.events_events(id);


--
-- Name: ticketing_registration_form_submissions fk_rails_675921f9b9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_form_submissions
    ADD CONSTRAINT fk_rails_675921f9b9 FOREIGN KEY (submitted_by_user_id) REFERENCES public.core_users(id);


--
-- Name: events_event_staff_assignments fk_rails_688c7d5175; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_staff_assignments
    ADD CONSTRAINT fk_rails_688c7d5175 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE CASCADE;


--
-- Name: ticketing_registration_consent_withdrawals fk_rails_6a3841f037; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_consent_withdrawals
    ADD CONSTRAINT fk_rails_6a3841f037 FOREIGN KEY (registration_consent_id) REFERENCES public.ticketing_registration_consents(id) ON DELETE RESTRICT;


--
-- Name: commercial_term_notices fk_rails_6a6c478930; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_term_notices
    ADD CONSTRAINT fk_rails_6a6c478930 FOREIGN KEY (fee_schedule_version_id) REFERENCES public.commercial_fee_schedule_versions(id) ON DELETE RESTRICT;


--
-- Name: ticketing_checkin_logs fk_rails_6c3a23a1af; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_checkin_logs
    ADD CONSTRAINT fk_rails_6c3a23a1af FOREIGN KEY (credential_id) REFERENCES public.ticketing_credentials(id);


--
-- Name: ticketing_ticket_suspensions fk_rails_6d28fce768; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_ticket_suspensions
    ADD CONSTRAINT fk_rails_6d28fce768 FOREIGN KEY (initiated_by_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_ticket_suspensions fk_rails_6e1f401ddd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_ticket_suspensions
    ADD CONSTRAINT fk_rails_6e1f401ddd FOREIGN KEY (event_id) REFERENCES public.events_events(id);


--
-- Name: events_event_participants fk_rails_7025684e48; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_participants
    ADD CONSTRAINT fk_rails_7025684e48 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE CASCADE;


--
-- Name: ticketing_registration_consents fk_rails_7187e20807; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_consents
    ADD CONSTRAINT fk_rails_7187e20807 FOREIGN KEY (registration_id) REFERENCES public.ticketing_registrations(id) ON DELETE RESTRICT;


--
-- Name: ticketing_tickets fk_rails_721a17e23c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_tickets
    ADD CONSTRAINT fk_rails_721a17e23c FOREIGN KEY (current_credential_generation_id) REFERENCES public.ticketing_credential_generations(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: commercial_event_payer_selections fk_rails_7357c14cd7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_event_payer_selections
    ADD CONSTRAINT fk_rails_7357c14cd7 FOREIGN KEY (selected_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: legal_acceptances fk_rails_73b4597b95; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_acceptances
    ADD CONSTRAINT fk_rails_73b4597b95 FOREIGN KEY (accepted_by_user_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: ticketing_credential_claims fk_rails_73e23c34b2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_credential_claims
    ADD CONSTRAINT fk_rails_73e23c34b2 FOREIGN KEY (invited_user_id) REFERENCES public.core_users(id);


--
-- Name: orders_orders fk_rails_7428b4bc83; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_orders
    ADD CONSTRAINT fk_rails_7428b4bc83 FOREIGN KEY (initiated_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: commercial_fee_schedule_versions fk_rails_75ae623228; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_schedule_versions
    ADD CONSTRAINT fk_rails_75ae623228 FOREIGN KEY (submitted_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


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
-- Name: commercial_fee_schedule_versions fk_rails_77e0620f60; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_schedule_versions
    ADD CONSTRAINT fk_rails_77e0620f60 FOREIGN KEY (approved_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: events_events fk_rails_784925b6cd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_events
    ADD CONSTRAINT fk_rails_784925b6cd FOREIGN KEY (created_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: commercial_fee_components fk_rails_79171aa877; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_components
    ADD CONSTRAINT fk_rails_79171aa877 FOREIGN KEY (fee_schedule_version_id) REFERENCES public.commercial_fee_schedule_versions(id) ON DELETE RESTRICT;


--
-- Name: commercial_fee_tiers fk_rails_79963d242d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_tiers
    ADD CONSTRAINT fk_rails_79963d242d FOREIGN KEY (fee_component_id) REFERENCES public.commercial_fee_components(id) ON DELETE RESTRICT;


--
-- Name: catalog_event_products fk_rails_7bf2218d4e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_event_products
    ADD CONSTRAINT fk_rails_7bf2218d4e FOREIGN KEY (event_id) REFERENCES public.events_events(id);


--
-- Name: ticketing_registrations fk_rails_7eab353b39; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registrations
    ADD CONSTRAINT fk_rails_7eab353b39 FOREIGN KEY (ticket_type_id) REFERENCES public.ticketing_ticket_types(id);


--
-- Name: catalog_promotion_products fk_rails_7ef1b6f2d2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_promotion_products
    ADD CONSTRAINT fk_rails_7ef1b6f2d2 FOREIGN KEY (promotion_id) REFERENCES public.catalog_promotions(id);


--
-- Name: ticketing_registration_form_versions fk_rails_815a640636; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_form_versions
    ADD CONSTRAINT fk_rails_815a640636 FOREIGN KEY (registration_form_id) REFERENCES public.ticketing_registration_forms(id);


--
-- Name: ticketing_registration_answers fk_rails_81e7027ae5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_answers
    ADD CONSTRAINT fk_rails_81e7027ae5 FOREIGN KEY (retention_policy_id) REFERENCES public.core_data_retention_policies(id);


--
-- Name: catalog_promotion_codes fk_rails_82ebe8867c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_promotion_codes
    ADD CONSTRAINT fk_rails_82ebe8867c FOREIGN KEY (promotion_id) REFERENCES public.catalog_promotions(id);


--
-- Name: ticketing_credentials fk_rails_8330f20be1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_credentials
    ADD CONSTRAINT fk_rails_8330f20be1 FOREIGN KEY (credential_generation_id) REFERENCES public.ticketing_credential_generations(id);


--
-- Name: commercial_simulations fk_rails_83d1a6fec2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_simulations
    ADD CONSTRAINT fk_rails_83d1a6fec2 FOREIGN KEY (fee_schedule_version_id) REFERENCES public.commercial_fee_schedule_versions(id) ON DELETE RESTRICT;


--
-- Name: commercial_fee_schedules fk_rails_83f8b09d29; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_schedules
    ADD CONSTRAINT fk_rails_83f8b09d29 FOREIGN KEY (created_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: ticketing_purchase_limit_allocations fk_rails_847accfc31; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_purchase_limit_allocations
    ADD CONSTRAINT fk_rails_847accfc31 FOREIGN KEY (ticket_type_id) REFERENCES public.ticketing_ticket_types(id);


--
-- Name: ticketing_credential_claims fk_rails_84c1b3174c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_credential_claims
    ADD CONSTRAINT fk_rails_84c1b3174c FOREIGN KEY (credential_id) REFERENCES public.ticketing_credentials(id);


--
-- Name: organizations_memberships fk_rails_84f4e71154; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations_memberships
    ADD CONSTRAINT fk_rails_84f4e71154 FOREIGN KEY (organization_id) REFERENCES public.organizations_organizations(id);


--
-- Name: ticketing_checkin_logs fk_rails_8540002031; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_checkin_logs
    ADD CONSTRAINT fk_rails_8540002031 FOREIGN KEY (ticket_id) REFERENCES public.ticketing_tickets(id);


--
-- Name: events_event_cancellations fk_rails_88de6f6294; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_cancellations
    ADD CONSTRAINT fk_rails_88de6f6294 FOREIGN KEY (initiated_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: orders_orders fk_rails_89368e7989; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_orders
    ADD CONSTRAINT fk_rails_89368e7989 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE RESTRICT;


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
-- Name: ticketing_credentials fk_rails_8e26720914; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_credentials
    ADD CONSTRAINT fk_rails_8e26720914 FOREIGN KEY (holder_user_id) REFERENCES public.core_users(id);


--
-- Name: events_event_dates fk_rails_8e99dedcd1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_dates
    ADD CONSTRAINT fk_rails_8e99dedcd1 FOREIGN KEY (venue_id) REFERENCES public.events_venues(id) ON DELETE SET NULL;


--
-- Name: ticketing_admission_use_reversals fk_rails_8f49c4b9f5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_admission_use_reversals
    ADD CONSTRAINT fk_rails_8f49c4b9f5 FOREIGN KEY (reversed_by_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_registration_answer_revisions fk_rails_92c24f7cf5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_answer_revisions
    ADD CONSTRAINT fk_rails_92c24f7cf5 FOREIGN KEY (registration_answer_id) REFERENCES public.ticketing_registration_answers(id);


--
-- Name: ticketing_purchase_limit_overrides fk_rails_97aeb24d0e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_purchase_limit_overrides
    ADD CONSTRAINT fk_rails_97aeb24d0e FOREIGN KEY (registration_id) REFERENCES public.ticketing_registrations(id);


--
-- Name: ticketing_admission_uses fk_rails_987a35c78c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_admission_uses
    ADD CONSTRAINT fk_rails_987a35c78c FOREIGN KEY (checkin_log_id) REFERENCES public.ticketing_checkin_logs(id);


--
-- Name: active_storage_variant_records fk_rails_993965df05; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT fk_rails_993965df05 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: ticketing_credential_revocations fk_rails_9a62d49bf9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_credential_revocations
    ADD CONSTRAINT fk_rails_9a62d49bf9 FOREIGN KEY (credential_id) REFERENCES public.ticketing_credentials(id);


--
-- Name: events_consent_document_versions fk_rails_9b125d6d31; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_consent_document_versions
    ADD CONSTRAINT fk_rails_9b125d6d31 FOREIGN KEY (created_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: ticketing_registration_forms fk_rails_9bc07d0d34; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_forms
    ADD CONSTRAINT fk_rails_9bc07d0d34 FOREIGN KEY (ticket_type_id) REFERENCES public.ticketing_ticket_types(id);


--
-- Name: ticketing_checkin_logs fk_rails_9be02e0597; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_checkin_logs
    ADD CONSTRAINT fk_rails_9be02e0597 FOREIGN KEY (scanner_device_assignment_id) REFERENCES public.ticketing_scanner_device_assignments(id);


--
-- Name: ticketing_registration_consent_withdrawals fk_rails_9d5543e235; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_consent_withdrawals
    ADD CONSTRAINT fk_rails_9d5543e235 FOREIGN KEY (withdrawn_by_user_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: ticketing_registration_form_versions fk_rails_9d857dc56a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_form_versions
    ADD CONSTRAINT fk_rails_9d857dc56a FOREIGN KEY (published_by_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_tickets fk_rails_9d9182e1f1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_tickets
    ADD CONSTRAINT fk_rails_9d9182e1f1 FOREIGN KEY (event_id) REFERENCES public.events_events(id);


--
-- Name: ticketing_scanner_assignment_zones fk_rails_9da19bf68b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_scanner_assignment_zones
    ADD CONSTRAINT fk_rails_9da19bf68b FOREIGN KEY (access_zone_id) REFERENCES public.events_access_zones(id);


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
-- Name: commercial_volume_usages fk_rails_a2ebf13ea8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_volume_usages
    ADD CONSTRAINT fk_rails_a2ebf13ea8 FOREIGN KEY (order_id) REFERENCES public.orders_orders(id) ON DELETE RESTRICT;


--
-- Name: ticketing_purchase_limit_allocations fk_rails_a3b4e1fe0e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_purchase_limit_allocations
    ADD CONSTRAINT fk_rails_a3b4e1fe0e FOREIGN KEY (scope_event_date_id) REFERENCES public.events_event_dates(id);


--
-- Name: commercial_fee_schedule_versions fk_rails_a65c6234ac; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_schedule_versions
    ADD CONSTRAINT fk_rails_a65c6234ac FOREIGN KEY (terminated_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: ticketing_purchase_limit_allocations fk_rails_a6be58a1a3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_purchase_limit_allocations
    ADD CONSTRAINT fk_rails_a6be58a1a3 FOREIGN KEY (user_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_checkin_logs fk_rails_abac9574b8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_checkin_logs
    ADD CONSTRAINT fk_rails_abac9574b8 FOREIGN KEY (event_date_id) REFERENCES public.events_event_dates(id);


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
-- Name: ticketing_checkin_logs fk_rails_ad2941f051; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_checkin_logs
    ADD CONSTRAINT fk_rails_ad2941f051 FOREIGN KEY (identity_override_by_id) REFERENCES public.core_users(id);


--
-- Name: events_event_video_links fk_rails_ad38a57f96; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_video_links
    ADD CONSTRAINT fk_rails_ad38a57f96 FOREIGN KEY (created_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: ticketing_registration_consent_withdrawals fk_rails_ad456e8b22; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_consent_withdrawals
    ADD CONSTRAINT fk_rails_ad456e8b22 FOREIGN KEY (registration_id) REFERENCES public.ticketing_registrations(id) ON DELETE RESTRICT;


--
-- Name: events_event_organizations fk_rails_ae4b4ed0bd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_organizations
    ADD CONSTRAINT fk_rails_ae4b4ed0bd FOREIGN KEY (organization_id) REFERENCES public.organizations_organizations(id) ON DELETE CASCADE;


--
-- Name: ticketing_scanner_device_assignments fk_rails_aee6e27c77; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_scanner_device_assignments
    ADD CONSTRAINT fk_rails_aee6e27c77 FOREIGN KEY (assigned_by_id) REFERENCES public.core_users(id);


--
-- Name: core_data_retention_holds fk_rails_b1e315a8f5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_data_retention_holds
    ADD CONSTRAINT fk_rails_b1e315a8f5 FOREIGN KEY (released_by_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_registration_consent_requirements fk_rails_b2527e9250; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_consent_requirements
    ADD CONSTRAINT fk_rails_b2527e9250 FOREIGN KEY (admission_slot_id) REFERENCES public.ticketing_admission_slots(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: commercial_simulations fk_rails_b2983c3a53; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_simulations
    ADD CONSTRAINT fk_rails_b2983c3a53 FOREIGN KEY (assignment_id) REFERENCES public.commercial_assignments(id) ON DELETE RESTRICT;


--
-- Name: ticketing_scanner_devices fk_rails_b34d6e75fe; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_scanner_devices
    ADD CONSTRAINT fk_rails_b34d6e75fe FOREIGN KEY (organization_id) REFERENCES public.organizations_organizations(id);


--
-- Name: ticketing_admission_slots fk_rails_b631cde906; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_admission_slots
    ADD CONSTRAINT fk_rails_b631cde906 FOREIGN KEY (assigned_user_id) REFERENCES public.core_users(id);


--
-- Name: orders_promotion_redemptions fk_rails_b84810ecf5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_promotion_redemptions
    ADD CONSTRAINT fk_rails_b84810ecf5 FOREIGN KEY (promotion_id) REFERENCES public.catalog_promotions(id) ON DELETE RESTRICT;


--
-- Name: ticketing_ticket_transfers fk_rails_b8d86feab9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_ticket_transfers
    ADD CONSTRAINT fk_rails_b8d86feab9 FOREIGN KEY (ticket_id) REFERENCES public.ticketing_tickets(id);


--
-- Name: events_event_video_links fk_rails_b98836a298; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_video_links
    ADD CONSTRAINT fk_rails_b98836a298 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE CASCADE;


--
-- Name: ticketing_revocations fk_rails_bb0a8d8c5d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_revocations
    ADD CONSTRAINT fk_rails_bb0a8d8c5d FOREIGN KEY (event_id) REFERENCES public.events_events(id);


--
-- Name: orders_refunds fk_rails_bc2590f2fc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_refunds
    ADD CONSTRAINT fk_rails_bc2590f2fc FOREIGN KEY (event_cancellation_id) REFERENCES public.events_event_cancellations(id) ON DELETE RESTRICT;


--
-- Name: legal_documents fk_rails_bd145f2b2b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_documents
    ADD CONSTRAINT fk_rails_bd145f2b2b FOREIGN KEY (created_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: commercial_simulations fk_rails_be1844990e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_simulations
    ADD CONSTRAINT fk_rails_be1844990e FOREIGN KEY (run_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: catalog_product_prices fk_rails_bfffbd73ae; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_prices
    ADD CONSTRAINT fk_rails_bfffbd73ae FOREIGN KEY (event_product_id) REFERENCES public.catalog_event_products(id);


--
-- Name: orders_orders fk_rails_c03b268463; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_orders
    ADD CONSTRAINT fk_rails_c03b268463 FOREIGN KEY (replaces_order_id) REFERENCES public.orders_orders(id) ON DELETE RESTRICT;


--
-- Name: ticketing_admission_uses fk_rails_c15631a62f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_admission_uses
    ADD CONSTRAINT fk_rails_c15631a62f FOREIGN KEY (admission_slot_id) REFERENCES public.ticketing_admission_slots(id);


--
-- Name: commercial_programs fk_rails_c261555096; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_programs
    ADD CONSTRAINT fk_rails_c261555096 FOREIGN KEY (fee_schedule_id) REFERENCES public.commercial_fee_schedules(id) ON DELETE RESTRICT;


--
-- Name: active_storage_attachments fk_rails_c3b3935057; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT fk_rails_c3b3935057 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: ticketing_ticket_suspensions fk_rails_c4fc895d9d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_ticket_suspensions
    ADD CONSTRAINT fk_rails_c4fc895d9d FOREIGN KEY (resolved_by_id) REFERENCES public.core_users(id);


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
-- Name: ticketing_checkin_logs fk_rails_ca1cf70263; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_checkin_logs
    ADD CONSTRAINT fk_rails_ca1cf70263 FOREIGN KEY (overrides_checkin_log_id) REFERENCES public.ticketing_checkin_logs(id);


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
-- Name: ticketing_attendee_index_entries fk_rails_ca756932ad; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_attendee_index_entries
    ADD CONSTRAINT fk_rails_ca756932ad FOREIGN KEY (credential_id) REFERENCES public.ticketing_credentials(id);


--
-- Name: ticketing_registration_form_submissions fk_rails_cad9e55600; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_form_submissions
    ADD CONSTRAINT fk_rails_cad9e55600 FOREIGN KEY (registration_form_version_id) REFERENCES public.ticketing_registration_form_versions(id);


--
-- Name: commercial_event_payer_selections fk_rails_cbe6016119; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_event_payer_selections
    ADD CONSTRAINT fk_rails_cbe6016119 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE RESTRICT;


--
-- Name: ticketing_invitations fk_rails_cc4a24abb3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_invitations
    ADD CONSTRAINT fk_rails_cc4a24abb3 FOREIGN KEY (invited_user_id) REFERENCES public.core_users(id);


--
-- Name: commercial_subsidy_budgets fk_rails_ceeebebef1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_subsidy_budgets
    ADD CONSTRAINT fk_rails_ceeebebef1 FOREIGN KEY (program_id) REFERENCES public.commercial_programs(id) ON DELETE RESTRICT;


--
-- Name: ticketing_purchase_limit_allocations fk_rails_cfd8f75ecd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_purchase_limit_allocations
    ADD CONSTRAINT fk_rails_cfd8f75ecd FOREIGN KEY (ticket_id) REFERENCES public.ticketing_tickets(id) DEFERRABLE INITIALLY DEFERRED;


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
-- Name: ticketing_credentials fk_rails_d371ab54a9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_credentials
    ADD CONSTRAINT fk_rails_d371ab54a9 FOREIGN KEY (ticket_id) REFERENCES public.ticketing_tickets(id);


--
-- Name: commercial_fee_schedule_versions fk_rails_d50634aedf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_schedule_versions
    ADD CONSTRAINT fk_rails_d50634aedf FOREIGN KEY (fee_schedule_id) REFERENCES public.commercial_fee_schedules(id) ON DELETE RESTRICT;


--
-- Name: commercial_subsidy_reservations fk_rails_d77a72289e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_subsidy_reservations
    ADD CONSTRAINT fk_rails_d77a72289e FOREIGN KEY (order_id) REFERENCES public.orders_orders(id) ON DELETE RESTRICT;


--
-- Name: core_reauthentication_proofs fk_rails_d799f90d96; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_reauthentication_proofs
    ADD CONSTRAINT fk_rails_d799f90d96 FOREIGN KEY (user_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_registration_consent_requirements fk_rails_d812807a6e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_consent_requirements
    ADD CONSTRAINT fk_rails_d812807a6e FOREIGN KEY (supersedes_requirement_id) REFERENCES public.ticketing_registration_consent_requirements(id) ON DELETE RESTRICT;


--
-- Name: commercial_assignments fk_rails_db4ae80025; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_assignments
    ADD CONSTRAINT fk_rails_db4ae80025 FOREIGN KEY (organization_id) REFERENCES public.organizations_organizations(id) ON DELETE RESTRICT;


--
-- Name: ticketing_purchase_limit_overrides fk_rails_dc9ec42e25; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_purchase_limit_overrides
    ADD CONSTRAINT fk_rails_dc9ec42e25 FOREIGN KEY (approved_by_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_ticket_suspensions fk_rails_dd58c808d6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_ticket_suspensions
    ADD CONSTRAINT fk_rails_dd58c808d6 FOREIGN KEY (ticket_id) REFERENCES public.ticketing_tickets(id);


--
-- Name: ticketing_credential_claims fk_rails_ddc2c6d9d0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_credential_claims
    ADD CONSTRAINT fk_rails_ddc2c6d9d0 FOREIGN KEY (claimed_by_user_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_registrations fk_rails_de5c6ebe08; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registrations
    ADD CONSTRAINT fk_rails_de5c6ebe08 FOREIGN KEY (access_code_id) REFERENCES public.ticketing_access_codes(id);


--
-- Name: core_user_roles fk_rails_e001d60739; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_user_roles
    ADD CONSTRAINT fk_rails_e001d60739 FOREIGN KEY (assigned_by_id) REFERENCES public.core_users(id);


--
-- Name: commercial_assignments fk_rails_e0088a0794; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_assignments
    ADD CONSTRAINT fk_rails_e0088a0794 FOREIGN KEY (fee_schedule_version_id) REFERENCES public.commercial_fee_schedule_versions(id) ON DELETE RESTRICT;


--
-- Name: ticketing_tickets fk_rails_e0532d8876; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_tickets
    ADD CONSTRAINT fk_rails_e0532d8876 FOREIGN KEY (order_item_id) REFERENCES public.orders_order_items(id);


--
-- Name: events_event_date_changes fk_rails_e0d0c7b105; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_date_changes
    ADD CONSTRAINT fk_rails_e0d0c7b105 FOREIGN KEY (event_date_id) REFERENCES public.events_event_dates(id) ON DELETE CASCADE;


--
-- Name: core_data_retention_holds fk_rails_e0e7ef8f82; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_data_retention_holds
    ADD CONSTRAINT fk_rails_e0e7ef8f82 FOREIGN KEY (user_id) REFERENCES public.core_users(id);


--
-- Name: events_event_participants fk_rails_e185aded17; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_participants
    ADD CONSTRAINT fk_rails_e185aded17 FOREIGN KEY (event_date_id) REFERENCES public.events_event_dates(id) ON DELETE CASCADE;


--
-- Name: commercial_assignments fk_rails_e2244fb635; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_assignments
    ADD CONSTRAINT fk_rails_e2244fb635 FOREIGN KEY (legal_acceptance_id) REFERENCES public.legal_acceptances(id) ON DELETE RESTRICT;


--
-- Name: commercial_subsidy_reservations fk_rails_e391bd89bb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_subsidy_reservations
    ADD CONSTRAINT fk_rails_e391bd89bb FOREIGN KEY (subsidy_budget_id) REFERENCES public.commercial_subsidy_budgets(id) ON DELETE RESTRICT;


--
-- Name: ticketing_credential_revocations fk_rails_e3e12f6332; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_credential_revocations
    ADD CONSTRAINT fk_rails_e3e12f6332 FOREIGN KEY (event_id) REFERENCES public.events_events(id);


--
-- Name: events_event_staff_assignments fk_rails_e3e6cd98cf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_staff_assignments
    ADD CONSTRAINT fk_rails_e3e6cd98cf FOREIGN KEY (user_id) REFERENCES public.core_users(id) ON DELETE CASCADE;


--
-- Name: ticketing_checkin_logs fk_rails_e4ade4718c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_checkin_logs
    ADD CONSTRAINT fk_rails_e4ade4718c FOREIGN KEY (identity_checked_by_id) REFERENCES public.core_users(id);


--
-- Name: commercial_fee_schedule_versions fk_rails_e5e937ec8b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_schedule_versions
    ADD CONSTRAINT fk_rails_e5e937ec8b FOREIGN KEY (legal_document_version_id) REFERENCES public.legal_document_versions(id) ON DELETE RESTRICT;


--
-- Name: ticketing_registration_answers fk_rails_e7291b9c65; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_answers
    ADD CONSTRAINT fk_rails_e7291b9c65 FOREIGN KEY (admission_slot_id) REFERENCES public.ticketing_admission_slots(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: orders_order_items fk_rails_e76003e058; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_order_items
    ADD CONSTRAINT fk_rails_e76003e058 FOREIGN KEY (order_id) REFERENCES public.orders_orders(id) ON DELETE RESTRICT;


--
-- Name: ticketing_attendee_exports fk_rails_e7e49b4233; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_attendee_exports
    ADD CONSTRAINT fk_rails_e7e49b4233 FOREIGN KEY (requested_by_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_credentials fk_rails_e86b021690; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_credentials
    ADD CONSTRAINT fk_rails_e86b021690 FOREIGN KEY (admission_slot_id) REFERENCES public.ticketing_admission_slots(id);


--
-- Name: ticketing_scanner_assignment_zones fk_rails_e98676d95b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_scanner_assignment_zones
    ADD CONSTRAINT fk_rails_e98676d95b FOREIGN KEY (scanner_device_assignment_id) REFERENCES public.ticketing_scanner_device_assignments(id);


--
-- Name: events_consent_document_versions fk_rails_eca35bc8df; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_consent_document_versions
    ADD CONSTRAINT fk_rails_eca35bc8df FOREIGN KEY (published_by_id) REFERENCES public.core_users(id) ON DELETE RESTRICT;


--
-- Name: ticketing_admission_use_reversals fk_rails_ed5529eef9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_admission_use_reversals
    ADD CONSTRAINT fk_rails_ed5529eef9 FOREIGN KEY (event_id) REFERENCES public.events_events(id);


--
-- Name: events_event_categories fk_rails_f01a03d541; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events_event_categories
    ADD CONSTRAINT fk_rails_f01a03d541 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE CASCADE;


--
-- Name: commercial_volume_usages fk_rails_f029ba26b4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_volume_usages
    ADD CONSTRAINT fk_rails_f029ba26b4 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE RESTRICT;


--
-- Name: ticketing_registrations fk_rails_f0bde43d6c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registrations
    ADD CONSTRAINT fk_rails_f0bde43d6c FOREIGN KEY (invitation_id) REFERENCES public.ticketing_invitations(id);


--
-- Name: ticketing_ticket_transfers fk_rails_f18db02b6c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_ticket_transfers
    ADD CONSTRAINT fk_rails_f18db02b6c FOREIGN KEY (from_user_id) REFERENCES public.core_users(id);


--
-- Name: ticketing_scan_uploads fk_rails_f2699a12eb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_scan_uploads
    ADD CONSTRAINT fk_rails_f2699a12eb FOREIGN KEY (scanner_device_assignment_id) REFERENCES public.ticketing_scanner_device_assignments(id);


--
-- Name: commercial_volume_counters fk_rails_f33e9b7151; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_volume_counters
    ADD CONSTRAINT fk_rails_f33e9b7151 FOREIGN KEY (event_id) REFERENCES public.events_events(id) ON DELETE RESTRICT;


--
-- Name: ticketing_attendee_exports fk_rails_f4991fd494; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_attendee_exports
    ADD CONSTRAINT fk_rails_f4991fd494 FOREIGN KEY (event_id) REFERENCES public.events_events(id);


--
-- Name: ticketing_registration_consents fk_rails_f852314892; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_consents
    ADD CONSTRAINT fk_rails_f852314892 FOREIGN KEY (retention_policy_id) REFERENCES public.core_data_retention_policies(id) ON DELETE RESTRICT;


--
-- Name: commercial_fee_schedule_versions fk_rails_f916345284; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_fee_schedule_versions
    ADD CONSTRAINT fk_rails_f916345284 FOREIGN KEY (supersedes_version_id) REFERENCES public.commercial_fee_schedule_versions(id) ON DELETE RESTRICT;


--
-- Name: ticketing_purchase_limit_overrides fk_rails_f9406187b7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_purchase_limit_overrides
    ADD CONSTRAINT fk_rails_f9406187b7 FOREIGN KEY (user_id) REFERENCES public.core_users(id);


--
-- Name: commercial_event_payer_selections fk_rails_fb9956ce8f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_event_payer_selections
    ADD CONSTRAINT fk_rails_fb9956ce8f FOREIGN KEY (fee_component_id) REFERENCES public.commercial_fee_components(id) ON DELETE RESTRICT;


--
-- Name: ticketing_registration_consents fk_rails_fb9e57a5c9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_consents
    ADD CONSTRAINT fk_rails_fb9e57a5c9 FOREIGN KEY (registration_consent_requirement_id) REFERENCES public.ticketing_registration_consent_requirements(id) ON DELETE RESTRICT;


--
-- Name: ticketing_registration_consent_requirements fk_rails_fba70d2488; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_consent_requirements
    ADD CONSTRAINT fk_rails_fba70d2488 FOREIGN KEY (registration_id) REFERENCES public.ticketing_registrations(id) ON DELETE RESTRICT;


--
-- Name: ticketing_registration_consent_requirements fk_rails_fca65b6fa3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_registration_consent_requirements
    ADD CONSTRAINT fk_rails_fca65b6fa3 FOREIGN KEY (consent_document_version_id) REFERENCES public.events_consent_document_versions(id) ON DELETE RESTRICT;


--
-- Name: ticketing_ticket_transfers fk_rails_fd014e0be6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_ticket_transfers
    ADD CONSTRAINT fk_rails_fd014e0be6 FOREIGN KEY (initiated_by_id) REFERENCES public.core_users(id);


--
-- Name: catalog_product_access_zones fk_rails_ffe7c83358; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_product_access_zones
    ADD CONSTRAINT fk_rails_ffe7c83358 FOREIGN KEY (product_access_id) REFERENCES public.catalog_product_accesses(id);


--
-- Name: ticketing_ticket_suspensions ticketing_ticket_suspensions_ticket_event_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ticketing_ticket_suspensions
    ADD CONSTRAINT ticketing_ticket_suspensions_ticket_event_fk FOREIGN KEY (ticket_id, event_id) REFERENCES public.ticketing_tickets(id, event_id) ON DELETE RESTRICT;


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260812090019'),
('20260812090018'),
('20260812090017'),
('20260812090016'),
('20260812090015'),
('20260812090014'),
('20260812090013'),
('20260812090012'),
('20260812090011'),
('20260812090010'),
('20260812090009'),
('20260812090008'),
('20260812090007'),
('20260812090006'),
('20260812090005'),
('20260812090004'),
('20260812090003'),
('20260812090002'),
('20260812090001'),
('20260811090010'),
('20260811090009'),
('20260811090008'),
('20260811090007'),
('20260811090006'),
('20260811090005'),
('20260811090004'),
('20260811090003'),
('20260811090002'),
('20260811090001'),
('20260808090012'),
('20260808090011'),
('20260808090010'),
('20260808090009'),
('20260808090008'),
('20260808090007'),
('20260808090006'),
('20260808090005'),
('20260808090004'),
('20260808090003'),
('20260808090002'),
('20260808090001'),
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
('20260727090117'),
('20260727090116'),
('20260727090115'),
('20260727090114'),
('20260727090113'),
('20260727090111'),
('20260727090110'),
('20260727090109'),
('20260727090108'),
('20260727090107'),
('20260727090106'),
('20260727090105'),
('20260727090104'),
('20260727090103'),
('20260727090102'),
('20260727090101'),
('20260727090100'),
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
