-- migrate:up
-- A staple's section: the name of the group it is shown under at its home, '' for none. Set
-- by the latest staple.added that names one, whose stamp is section_hlc; a section is nothing
-- but this name.
ALTER TABLE staples ADD COLUMN section TEXT NOT NULL DEFAULT '';
ALTER TABLE staples ADD COLUMN section_hlc TEXT;

-- migrate:down
ALTER TABLE staples DROP COLUMN section_hlc;
ALTER TABLE staples DROP COLUMN section;
