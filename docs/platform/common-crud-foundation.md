# Core Common CRUD Foundation

## Scope

Reusable controller concerns copied and adapted from `dscf-core`:

- `Core::Common`
- `Core::Filterable`
- `Core::Pagination`

These are generic API helpers for low-risk CRUD endpoints.

## `Core::Common`

Provides:

- `index`
- `show`
- `create`
- `update`
- `destroy`

With built-in:

- Pundit authorization hooks
- optional eager loading override
- serializer include override per action
- optional pagination metadata
- consistent response envelopes

Required override in consuming controller:

```ruby
def model_params
  params.require(:resource).permit(...)
end
```

Optional overrides:

- `eager_loaded_associations` — derives from `serializer_profile` by default; override for deeper preload
- `allowed_order_columns`
- `serializer_profile`
- `after_save_hook(record)`

## Filtering

`Core::Filterable` uses Ransack via `params[:q]`.

Models inheriting from `Core::ApplicationRecord` already expose default:

- `ransackable_attributes`
- `ransackable_associations`

For sensitive resources, override these methods per model with strict allowlists.

## Pagination

`Core::Pagination` supports:

- `page`
- `per_page`
- `order_by`
- `order_direction`

Defaults:

- `per_page: 25`
- max `per_page: 100`
- `order_direction: desc`

Response includes HATEOAS-style page links in `pagination.links`.

## Usage Guidance

Use `Core::Common` for admin/config CRUD.

Prefer explicit controllers for critical flows such as ticket checkout, transfer, scan, and offline sync where business rules should remain visible.
