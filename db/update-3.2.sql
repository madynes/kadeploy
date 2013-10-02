--
-- Rename field in the table `log`
--
ALTER TABLE `log` CHANGE `deploy_id` `wid` varchar(41) NOT NULL;
