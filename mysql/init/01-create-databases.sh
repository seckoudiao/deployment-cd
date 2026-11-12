#!/bin/bash
# Crée l'utilisateur applicatif et les bases des microservices (premier démarrage uniquement).
# APP_DB_USER / APP_DB_PASSWORD sont fournis par docker-compose.yml (depuis .env et secrets.env).
set -e

mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
    CREATE USER IF NOT EXISTS '${APP_DB_USER}'@'%' IDENTIFIED BY '${APP_DB_PASSWORD}';

    CREATE DATABASE IF NOT EXISTS identity_db     CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE DATABASE IF NOT EXISTS institution_db  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE DATABASE IF NOT EXISTS academic_db     CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE DATABASE IF NOT EXISTS matching_db     CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE DATABASE IF NOT EXISTS resource_db     CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE DATABASE IF NOT EXISTS notification_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

    -- Moindre privilège : l'utilisateur applicatif n'a des droits que sur ces bases
    GRANT ALL PRIVILEGES ON identity_db.*     TO '${APP_DB_USER}'@'%';
    GRANT ALL PRIVILEGES ON institution_db.*  TO '${APP_DB_USER}'@'%';
    GRANT ALL PRIVILEGES ON academic_db.*     TO '${APP_DB_USER}'@'%';
    GRANT ALL PRIVILEGES ON matching_db.*     TO '${APP_DB_USER}'@'%';
    GRANT ALL PRIVILEGES ON resource_db.*     TO '${APP_DB_USER}'@'%';
    GRANT ALL PRIVILEGES ON notification_db.* TO '${APP_DB_USER}'@'%';
    FLUSH PRIVILEGES;
EOSQL

echo "Utilisateur ${APP_DB_USER} et bases Jangalma créés."
