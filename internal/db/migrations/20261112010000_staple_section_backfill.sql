-- migrate:up
-- Sections named while a server from before them was running are in the log but not in the
-- table: it kept the events and folded them without the section. Each staple takes the section
-- of the latest staple.added in the log that names one, as the fold would have given it.
UPDATE staples SET
  section = (SELECT json_extract(e.payload, '$.section') FROM events e
    WHERE e.household_id = staples.household_id AND e.kind = 'staple.added'
      AND json_extract(e.payload, '$.home_id') = staples.home_id
      AND json_extract(e.payload, '$.item_id') = staples.item_id
      AND json_type(e.payload, '$.section') = 'text'
    ORDER BY e.hlc DESC LIMIT 1),
  section_hlc = (SELECT e.hlc FROM events e
    WHERE e.household_id = staples.household_id AND e.kind = 'staple.added'
      AND json_extract(e.payload, '$.home_id') = staples.home_id
      AND json_extract(e.payload, '$.item_id') = staples.item_id
      AND json_type(e.payload, '$.section') = 'text'
    ORDER BY e.hlc DESC LIMIT 1)
WHERE EXISTS (SELECT 1 FROM events e
    WHERE e.household_id = staples.household_id AND e.kind = 'staple.added'
      AND json_extract(e.payload, '$.home_id') = staples.home_id
      AND json_extract(e.payload, '$.item_id') = staples.item_id
      AND json_type(e.payload, '$.section') = 'text');

-- migrate:down
SELECT 1;
