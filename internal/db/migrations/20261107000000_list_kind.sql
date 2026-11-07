-- migrate:up
-- A list's kind: '' is a shopping list, 'tasks' a list of things to do. Set once, by
-- list.created, and read by the screens, the overviews and the export; everything else about
-- a list and its entries is the same.
ALTER TABLE lists ADD COLUMN kind TEXT NOT NULL DEFAULT '';

-- migrate:down
ALTER TABLE lists DROP COLUMN kind;
