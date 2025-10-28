#!/bin/bash

sudo apt-get update -y && sudo apt-get install make

make clean
make config

# Charger les variables depuis le fichier artifacts (après make config)
if [ -f "artifacts" ]; then
    # Convertir les exports Make en exports Bash
    source <(grep "^export" artifacts | sed 's/export /export /')
fi

# Vérifier que le webhook Discord est configuré
if [ -z "$DISCORD_WEBHOOK_URL" ]; then
    echo "⚠️  DISCORD_WEBHOOK_URL n'est pas définie. Les notifications Discord seront ignorées."
    DISCORD_ENABLED=false
else
    DISCORD_ENABLED=true
fi

# Fonction pour envoyer une notification Discord
send_discord_notification() {
    if [ "$DISCORD_ENABLED" = true ]; then
        curl -s -H "Content-Type: application/json" \
             -X POST \
             -d "{\"content\": \"$1\"}" \
             "$DISCORD_WEBHOOK_URL" > /dev/null
    fi
}


# Copier le backup dans backend
cp -r ../backup/upload ./backend/upload

make datagouv-to-upload

make recipe-run
make watch-run

# === PREMIÈRE NOTIFICATION : Statistiques d'indexation ===
LOG_FILE=$(find backend/log/ -iname '*deces_dataprep*' | sort | tail -1)

if [ -f "$LOG_FILE" ]; then
    # Extraire le nombre de lignes traitées et écrites
    STATS=$(grep "successfully fininshed" "$LOG_FILE" | tail -1)
    LINES_PROCESSED=$(echo "$STATS" | sed -n 's/.*\([0-9]\{8,\}\) lines processed.*/\1/p')
    LINES_WRITTEN=$(echo "$STATS" | sed -n 's/.*\([0-9]\{8,\}\) lines written.*/\1/p')
    
    # Calculer la durée
    START_TIME=$(head -1 "$LOG_FILE" | awk '{print $1" "$2}')
    END_TIME=$(grep "end of all" "$LOG_FILE" | awk '{print $1" "$2}')
    
    # Envoyer la notification d'indexation
    send_discord_notification "✅ **Indexation des décès terminée !**\n\n📊 **Statistiques :**\n• Lignes traitées : **${LINES_PROCESSED}**\n• Lignes écrites : **${LINES_WRITTEN}**\n• Début : ${START_TIME}\n• Fin : ${END_TIME}"
else
    send_discord_notification "❌ **Erreur : fichier de log introuvable**"
fi

# === Création des backups ===
make backup-dir
make backup

cp -r ./backend/upload ../backup/

rm -rf ../backup/backup
cp -r ./backend/backup ../backup/

# === DEUXIÈME NOTIFICATION : Confirmation backups ===
send_discord_notification "💾 **Backups à jour !**\n\nLes backups locaux ont été créés avec succès dans \`../backup/\`"
