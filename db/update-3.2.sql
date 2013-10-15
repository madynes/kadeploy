--
-- Rename field in the table `log`
--
UPDATE `log` SET deploy_id = CONCAT('D-',deploy_id);
ALTER TABLE `log` CHANGE `deploy_id` `wid` varchar(41) NOT NULL;
