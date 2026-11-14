// =====================================================================================
// Pipeline CD de Jangalma : déploie automatiquement les images publiées par la CI.
//
// Déclenchement :
//   - après chaque build réussi de backend-ci ou frontend-ci (nouvelles images sur Docker Hub) ;
//   - à chaque modification de ce dépôt (docker-compose.yml, .env, scripts) ;
//   - manuellement (« Lancer un build »).
//
// Prérequis Jenkins (credentials) :
//   - jangalma-secrets-env : « Secret file » = le fichier secrets.env (mots de passe, clé JWT...)
//   - dockerhub-credentials : déjà utilisé par la CI (évite la limite de téléchargements anonymes)
//   - discord-webhook (facultatif) : « Secret text » = URL d'un webhook Discord pour les notifications
// =====================================================================================
pipeline {
    agent any

    triggers {
        upstream(upstreamProjects: 'backend-ci,frontend-ci', threshold: hudson.model.Result.SUCCESS)
        pollSCM('H/5 * * * *')
    }

    options {
        disableConcurrentBuilds()          // jamais deux déploiements en même temps
        timeout(time: 45, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timestamps()
    }

    environment {
        HEALTH_TIMEOUT_S = '300'
        DRAIN_S          = '20'
    }

    stages {
        stage('Contexte') {
            steps {
                script {
                    def causes = currentBuild.getBuildCauses()*.shortDescription.join(', ')
                    echo "Déclenché par : ${causes}"
                    currentBuild.description = causes
                }
                sh 'docker version --format "Docker {{.Server.Version}}" && docker compose version'
            }
        }

        stage('Connexion Docker Hub') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub-credentials',
                                                  usernameVariable: 'DOCKER_USER',
                                                  passwordVariable: 'DOCKER_PASS')]) {
                    sh 'echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin'
                }
            }
        }

        stage('Validation de la configuration') {
            steps {
                withCredentials([file(credentialsId: 'jangalma-secrets-env', variable: 'SECRETS_ENV')]) {
                    sh 'docker compose --env-file .env --env-file "$SECRETS_ENV" config --quiet'
                }
            }
        }

        stage('Déploiement progressif') {
            steps {
                withCredentials([file(credentialsId: 'jangalma-secrets-env', variable: 'SECRETS_ENV')]) {
                    sh 'bash scripts/deploy.sh'
                }
            }
        }

        stage('Contrôle post-déploiement') {
            steps {
                sh 'bash scripts/verifier.sh'
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'deploy-report.txt', allowEmptyArchive: true
            sh 'docker logout || true'
        }
        success {
            script { notifier("✅ Jangalma déployé avec succès (build #${env.BUILD_NUMBER}) : ${env.BUILD_URL}") }
        }
        failure {
            script { notifier("❌ Échec du déploiement Jangalma (build #${env.BUILD_NUMBER}) : ${env.BUILD_URL}console") }
        }
    }
}

// Envoie un message sur Discord si le credential « discord-webhook » existe ; sinon, simple trace.
def notifier(String message) {
    echo "NOTIFICATION : ${message}"
    try {
        withCredentials([string(credentialsId: 'discord-webhook', variable: 'WEBHOOK')]) {
            withEnv(["MESSAGE=${message}"]) {
                sh '''
                    payload=$(printf '{"content": "%s"}' "$MESSAGE")
                    curl -fsS -m 10 -H "Content-Type: application/json" -d "$payload" "$WEBHOOK" >/dev/null
                '''
            }
        }
    } catch (e) {
        echo "Notification Discord non envoyée (credential discord-webhook absent ou erreur) : ${e.message}"
    }
}
