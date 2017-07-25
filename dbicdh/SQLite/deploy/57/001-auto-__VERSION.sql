-- 
-- Created by SQL::Translator::Producer::SQLite
<<<<<<< HEAD
-- Created on Wed Jul 19 10:43:19 2017
||||||| parent of 317d4804... Disable feature tour by seeting database entry to zero
-- Created on Wed Jul  5 14:04:56 2017
=======
-- Created on Tue Jul 25 14:29:07 2017
>>>>>>> 317d4804... Disable feature tour by seeting database entry to zero
-- 

;
BEGIN TRANSACTION;
--
-- Table: dbix_class_deploymenthandler_versions
--
CREATE TABLE dbix_class_deploymenthandler_versions (
  id INTEGER PRIMARY KEY NOT NULL,
  version varchar(50) NOT NULL,
  ddl text,
  upgrade_sql text
);
CREATE UNIQUE INDEX dbix_class_deploymenthandler_versions_version ON dbix_class_deploymenthandler_versions (version);
COMMIT;
