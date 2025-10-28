#!/bin/bash
#===============================================================================
# Script: run-local-ES-update.sh
# Description: Mise à jour locale d'Elasticsearch avec les données de décès.
#
# Étapes principales:
#   1. Préparation de l'environnement (dépendances, configuration).
#   2. Traitement des données (datagouv -> upload -> recipe).
#   3. Notification Discord avec les statistiques d'indexation.
#   4. Création et archivage des backups locaux.
#
# Prérequis:
#   - Commande 'make' disponible.
#   - Fichier '../backup/upload' doit exister.
#   - DISCORD_WEBHOOK_URL défini dans le fichier 'artifacts' (optionnel).
#===============================================================================

#===============================================================================
# CONFIGURATION ET INITIALISATION
#===============================================================================

# Arrêter le script en cas d'erreur
set -e
trap 'echo "❌ Erreur détectée à la ligne $LINENO"' ERR

# Variables de chemins pour une meilleure lisibilité
BACKUP_SOURCE_DIR="../backup/upload"
BACKEND_UPLOAD_DIR="./backend/upload"
BACKEND_BACKUP_DIR="./backend/backup"
BACKUP_DEST_DIR="../backup/"

#===============================================================================
# FONCTIONS
#===============================================================================

# Fonction pour afficher les en-têtes de section
print_header() {
    echo ""
    echo "==============================================================================="
    echo " $1"
    echo "==============================================================================="
}

# Fonction pour charger les variables d'environnement depuis le fichier 'artifacts'
load_environment_variables() {
    print_header "ÉTAPE 1/5 : Chargement des variables d'environnement"
    if [ -f "artifacts" ]; then
        # Convertir les exports Make en exports Bash
        source <(grep "^export" artifacts | sed 's/export /export /')
        echo "✅ Variables d'environnement chargées depuis 'artifacts'."
    else
        echo "⚠️  Fichier 'artifacts' introuvable. Certaines fonctionnalités pourraient ne pas être disponibles."
    fi
}

# Fonction pour configurer les notifications Discord
setup_discord_notifications() {
    print_header "ÉTAPE 2/5 : Configuration des notifications Discord"
    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
        echo "⚠️  DISCORD_WEBHOOK_URL n'est pas définie. Les notifications Discord seront ignorées."
        DISCORD_ENABLED=false
    else
        echo "✅ Notifications Discord activées."
        DISCORD_ENABLED=true
    fi
}

# Fonction pour envoyer une notification Discord
send_discord_notification() {
    if [ "$DISCORD_ENABLED" = true ]; then
        # Le -s silent mode évite d'afficher la sortie de curl
        curl -s -H "Content-Type: application/json" \
             -X POST \
             -d "{\"content\": \"$1\"}" \
             "$DISCORD_WEBHOOK_URL" > /dev/null
    fi
}

# Fonction pour exécuter le traitement des données
run_data_processing() {
    print_header "ÉTAPE 3/5 : Traitement des données"
    
    echo "📦 Copie du backup initial vers le backend..."
    cp -r "$BACKUP_SOURCE_DIR" "$BACKEND_UPLOAD_DIR"
    
    echo "🚚 Transfert des données de datagouv vers l'upload..."
    make datagouv-to-upload
    
    echo "🍳 Exécution de la recette de préparation des données..."
    make recipe-run
    make watch-run
    echo "✅ Traitement des données terminé."
}

# Fonction pour envoyer les statistiques d'indexation
send_indexation_stats() {
    print_header "ÉTAPE 4/5 : Envoi des statistiques d'indexation"
    local LOG_FILE
    LOG_FILE=$(find backend/log/ -iname '*deces_dataprep*' | sort | tail -1)

    if [ -f "$LOG_FILE" ]; then
        local STATS LINES_PROCESSED LINES_WRITTEN START_TIME END_TIME ES_DOC_COUNT
        STATS=$(grep "successfully fininshed" "$LOG_FILE" | tail -1)
        LINES_PROCESSED=$(echo "$STATS" | sed -n 's/.*\([0-9]\{7,\}\) lines processed.*/\1/p')
        LINES_WRITTEN=$(echo "$STATS" | sed -n 's/.*\([0-9]\{7,\}\) lines written.*/\1/p')
        
        START_TIME=$(head -1 "$LOG_FILE" | awk '{print $1" "$2}')
        END_TIME=$(grep "end of all" "$LOG_FILE" | awk '{print $1" "$2}')

        # Récupérer le nombre de documents depuis Elasticsearch
        ES_DOC_COUNT=$(curl -s localhost:9200/_cat/indices | grep "deces" | awk '{print $7}')
        
        local message="✅ **Indexation des décès terminée !**\n\n📊 **Statistiques :**\n• Lignes traitées : **${LINES_PROCESSED}**\n• Lignes écrites : **${LINES_WRITTEN}**\n• Documents dans l'index : **${ES_DOC_COUNT}**\n• Début : ${START_TIME}\n• Fin : ${END_TIME}"
        send_discord_notification "$message"
        echo "📊 Statistiques d'indexation envoyées."
    else
        send_discord_notification "❌ **Erreur : fichier de log introuvable**"
        echo "❌ Fichier de log introuvable. Impossible d'envoyer les statistiques."
    fi
}

# Fonction pour créer les backups
create_backups() {
    print_header "ÉTAPE 5/5 : Création des backups locaux"
    
    echo "📁 Création du répertoire de backup..."
    make backup-dir
    make backup
    
    echo "🔄 Synchronisation des backups..."
    # Copie de l'upload mis à jour
    cp -r "$BACKEND_UPLOAD_DIR" "$BACKUP_DEST_DIR"
    
    # Remplacement de l'ancien backup par le nouveau
    rm -rf "${BACKUP_DEST_DIR}/backup"
    cp -r "$BACKEND_BACKUP_DIR" "$BACKUP_DEST_DIR"
    
    local message="💾 **Backups locaux à jour !**\n\nLes backups ont été créés avec succès dans \`$BACKUP_DEST_DIR\`"
    send_discord_notification "$message"
    echo "✅ Backups créés avec succès dans '$BACKUP_DEST_DIR'."
}


#===============================================================================
# SCRIPT PRINCIPAL
#===============================================================================

main() {
    print_header "Démarrage du script de mise à jour locale d'Elasticsearch"

    sudo apt-get update -y && sudo apt-get install make -y
    make clean
    make config

    load_environment_variables
    setup_discord_notifications
    run_data_processing
    send_indexation_stats
    create_backups

    print_header "🎉 Script terminé avec succès."
}

# Exécuter la fonction principale
main
