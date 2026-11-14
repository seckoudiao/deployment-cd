# deployment-cd — Déploiement de Jangalma

Déploiement de **Jangalma**, plateforme de tutorat et de partage de ressources pédagogiques de l'UADB :
Docker Compose pour lancer toute l'application, Jenkins pour la déployer automatiquement (CD).

| Dépôt | Rôle |
|---|---|
| [frontend-ci](https://github.com/Seydina-Ibrahima-DIENG/frontend-ci) | Angular + nginx, pipeline CI |
| [backend-ci](https://github.com/Falilou66/backend-ci) | 7 microservices Spring Boot, pipeline CI |
| **deployment-cd** (ce dépôt) | Docker Compose, pipeline CD |

Les images sont publiques sur Docker Hub (`seckou04/jangalma-*`) : rien n'est compilé sur votre machine.

---

## 1. Lancer Jangalma chez soi (≈ 10 minutes)

### Prérequis
- **Docker Desktop** démarré (Windows, macOS ou Linux)
- **6 Go de RAM libres** et **~3 Go d'espace disque**
- Le port **8088** libre (sinon, changez `APP_PORT` dans `.env`)

### Étapes (PowerShell, Windows)
```powershell
git clone https://github.com/seckoudiao/deployment-cd.git
cd deployment-cd

# 1) Générer VOS secrets (mots de passe aléatoires). Le mot de passe admin s'affiche : notez-le.
powershell -ExecutionPolicy Bypass -File scripts\generer-secrets.ps1

# 2) Démarrer l'application (premier lancement : téléchargement ~2 Go, puis 3 à 4 min de démarrage)
docker compose --env-file .env --env-file secrets.env up -d

# 3) Suivre le démarrage : attendre que les 10 services soient "(healthy)"
docker compose --env-file .env --env-file secrets.env ps
```

> **macOS / Linux** : copiez `secrets.env.example` en `secrets.env` et remplacez chaque valeur
> (`openssl rand -hex 16` pour un mot de passe, `openssl rand -base64 48` pour `JWT_SECRET`).

### Utiliser l'application
Ouvrez **http://localhost:8088**.

| Action | Comment |
|---|---|
| Créer un compte étudiant ou enseignant | « Créer un compte » — email **@uadb.edu.sn** obligatoire |
| Se connecter en administrateur | `admin@uadb.edu.sn` + le mot de passe affiché à l'étape 1 |
| Voir les services enregistrés | http://localhost:8761 (tableau de bord Eureka) |

Chaque installation a **sa propre base de données** : les comptes créés chez vous n'existent que chez vous.

### Arrêter / relancer
```powershell
docker compose --env-file .env --env-file secrets.env stop     # arrêter (données conservées)
docker compose --env-file .env --env-file secrets.env start    # relancer
docker compose --env-file .env --env-file secrets.env down     # supprimer les conteneurs (données conservées)
```
⚠️ N'ajoutez **jamais `-v`** à `down` sauf pour tout effacer : cela supprime la base de données et les fichiers.

### En cas de problème
| Symptôme | Solution |
|---|---|
| Un service reste `(health: starting)` | Normal pendant 2-3 min (services Java) ; sinon `docker compose ... logs <service>` |
| `port is already allocated` sur 8088 | Changez `APP_PORT=8089` dans `.env`, puis relancez `up -d` |
| Erreur de connexion à MySQL après avoir régénéré `secrets.env` | MySQL garde les mots de passe de sa création : `down -v` puis `up -d` (efface les données) |
| La page affiche une erreur 503 juste après le démarrage | La gateway attend les services : patientez 30 s et rechargez |

---

## 2. Architecture déployée

```
Navigateur ──► frontend (nginx, port 8088) ──/api──► api-gateway ──► Eureka (découverte)
                                                          │
                     identity · academic · matching · resource · notification
                                                          │
                                          MySQL (6 bases)  ·  MinIO (fichiers)
```

- **Seul le frontend est exposé** ; Eureka (8761) et la console MinIO (9001) ne sont accessibles que depuis la machine (127.0.0.1).
- **Persistance** : volumes Docker `mysql_data` et `minio_data`, conservés entre les redéploiements.
- **Health checks** sur chaque service ; démarrage ordonné (MySQL et Eureka avant les microservices).
- **Secrets** hors de Git : configuration non sensible dans `.env` (versionné), mots de passe dans `secrets.env` (ignoré par Git).
- **Administrateur initial** créé automatiquement au premier démarrage (variables `BOOTSTRAP_ADMIN_*`).

---

## 3. Pipeline CD (Jenkins)

Le `Jenkinsfile` de ce dépôt définit le job **deployment-cd**, déclenché :
- automatiquement après chaque build réussi de **backend-ci** ou **frontend-ci** (nouvelles images sur Docker Hub) ;
- à chaque modification de ce dépôt (vérification toutes les 5 min) ;
- manuellement.

| Étape | Rôle |
|---|---|
| Connexion Docker Hub | évite la limite de téléchargements anonymes |
| Validation de la configuration | `docker compose config` avec les secrets fournis par Jenkins |
| Déploiement progressif | `scripts/deploy.sh` (voir ci-dessous) |
| Contrôle post-déploiement | `scripts/verifier.sh` : conteneurs healthy, inscriptions Eureka, parcours utilisateur via nginx |
| Notification | console Jenkins + Discord si le credential `discord-webhook` existe ; rapport `deploy-report.txt` archivé |

### Déploiement sans coupure (`scripts/deploy.sh`)
Pour chaque service dont **l'image ou la configuration a changé** (les autres ne sont pas touchés) :
1. une **2ᵉ instance** démarre avec la nouvelle version, l'ancienne continue de répondre ;
2. on attend qu'elle soit **healthy** — sinon elle est supprimée et l'ancienne reste en place (**rollback**) ;
3. l'ancienne est **retirée d'Eureka**, le trafic bascule (20 s) ;
4. l'ancienne est **arrêtée proprement** (requêtes en cours terminées).

MySQL et MinIO ne sont jamais recréés. Mesure faite avec une sonde (1 requête / 1,5 s) pendant le
redéploiement d'identity-service et academic-service : **0 erreur**.

Limites connues : Eureka et le frontend (port 8088 publié) n'ont qu'une instance ; leur remplacement
peut provoquer quelques secondes d'indisponibilité. Ils changent rarement.

Démonstration (redéployer des services sans changement) :
```bash
FORCER="identity-service api-gateway" SECRETS_ENV=secrets.env bash scripts/deploy.sh
bash scripts/verifier.sh
```

### Configuration Jenkins requise
| Credential (ID) | Type | Contenu |
|---|---|---|
| `jangalma-secrets-env` | Secret file | le fichier `secrets.env` de production |
| `dockerhub-credentials` | Username/password | compte Docker Hub (déjà utilisé par la CI) |
| `discord-webhook` (facultatif) | Secret text | URL d'un webhook Discord |

Job : *Pipeline script from SCM*, dépôt `https://github.com/seckoudiao/deployment-cd.git`, branche `*/main`.
Lancer **un premier build manuellement** pour activer les déclencheurs.

---

## 4. Contenu du dépôt

| Fichier | Rôle |
|---|---|
| `docker-compose.yml` | les 10 services, volumes, health checks |
| `.env` | configuration non sensible (tags d'images, port, comptes) |
| `secrets.env.example` | liste des secrets attendus (modèle) |
| `mysql/` | image MySQL + scripts de création des bases |
| `scripts/generer-secrets.ps1` | génération de `secrets.env` aléatoire |
| `scripts/deploy.sh` | déploiement progressif sans coupure |
| `scripts/verifier.sh` | contrôle post-déploiement |
| `Jenkinsfile` | pipeline CD |
