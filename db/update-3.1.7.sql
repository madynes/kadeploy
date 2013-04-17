--
-- New field in the table `environments`
--
ALTER TABLE `environments` ADD `multipart` boolean NOT NULL default FALSE;
ALTER TABLE `environments` ADD `options` TEXT NULL default NULL;
