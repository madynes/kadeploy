#!/bin/bash

mysql <<< "DROP DATABASE IF EXISTS deploy3;\nCREATE DATABASE deploy3;\nGRANT select, insert, update, delete, create, drop, alter,  create temporary tables, lock tables ON deploy3.*  TO 'deploy'@'localhost';\nSET PASSWORD FOR 'deploy'@'localhost' = PASSWORD('deploy-password');\nuse deploy3;\nsource /vagrant/db/db_creation.sql;"
