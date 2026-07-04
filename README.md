# SecurePulse - Architecture Stockage Distribué Multi-Site

Ce dépôt contient la configuration de l'architecture de stockage hautement disponible et **Anti-SPOF** pour le projet annuel **SecurePulse**. Elle repose sur **GlusterFS** conteneurisé avec Docker, simulant un déploiement sur trois sites géographiques : **Paris**, **Lille** et **Lyon**.

## 🚀 Architecture & Concepts

- **Multi-Site & Zéro SPOF** : Les données sont répliquées de manière synchrone sur les 3 nœuds (`replica 3`). La perte d'un ou deux sites n'entraîne aucune perte de données ni d'interruption de service.
- **Réseau Dédié** : Un sous-réseau Docker (`172.20.0.0/16`) isole le trafic de réplication.

## 📁 Structure du Projet

```text
├── .github/workflows/
│   └── test-storage.yml   # CI/CD - Tests automatiques GitHub Actions
├── docker-compose.yml     # Définition des nœuds Paris, Lille, Lyon
├── cluster-init.sh        # Script d'initialisation du cluster et du volume
└── README.md              # Documentation du projet