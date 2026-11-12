# MySQL officiel + scripts d'initialisation intégrés à l'image.
# Pourquoi une image plutôt qu'un montage ./mysql/init ? Jenkins pilote le Docker de la machine
# via docker.sock : un chemin du workspace Jenkins n'existe pas pour le moteur Docker.
# Le contexte de build, lui, est envoyé au moteur : les scripts arrivent bien dans l'image.
FROM mysql:8.4

# Exécutés une seule fois, au premier démarrage (quand le volume de données est vide), par ordre alphabétique
COPY init/ /docker-entrypoint-initdb.d/
