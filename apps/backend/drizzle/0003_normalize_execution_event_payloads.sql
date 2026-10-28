-- Older workers stored serialized objects and arrays as jsonb string scalars.
UPDATE "execution_events"
SET "payload_json" = ("payload_json" #>> '{}')::jsonb
WHERE jsonb_typeof("payload_json") = 'string'
  AND left("payload_json" #>> '{}', 1) IN ('{', '[');