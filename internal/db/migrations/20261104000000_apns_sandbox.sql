-- migrate:up
-- Which of Apple's two push gateways a device's token belongs to: a build installed from
-- Xcode registers a development token, a TestFlight or App Store build a production one. The
-- device says so when it registers, and the server sends each push to the matching host.
ALTER TABLE credentials ADD COLUMN apns_sandbox INTEGER NOT NULL DEFAULT 0;

-- migrate:down
ALTER TABLE credentials DROP COLUMN apns_sandbox;
