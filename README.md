# VecturaDB.Deploy

Templates that run Chroma 1.5.9 or VecturaDB in your own cloud account.

For now they are for Azure:

- [azure/vm](azure/vm/): one Azure VM with Docker and Caddy, HTTPS, allowed IP addresses, the data on a managed disk and backups with Azure Disk Backup. The one we recommend.
- [azure/container-apps](azure/container-apps/): Chroma 1.5.9 on Azure Container Apps, with the data on Azure Files SMB and scale to zero, for a few hours of use a day. Read its limits first.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FVecturaDB%2FVecturaDB.Deploy%2Fazure-v1.0.2%2Fazure%2Fvm%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FVecturaDB%2FVecturaDB.Deploy%2Fazure-v1.0.2%2Fazure%2Fvm%2FcreateUiDefinition.json)

The page of the template on the website: [vecturadb.org/deploy/chroma](https://vecturadb.org/deploy/chroma/).

## License

Apache License 2.0. The templates and their scripts are provided as is, without warranty of any kind. Back up your data and test a restore before you rely on it. Not sure about your case? Open an issue in this repository.

VecturaDB is an independent fork of Chroma, under the Apache License 2.0. The original code is copyright Chroma Inc. and its contributors.

Not affiliated with, endorsed by or sponsored by Chroma Inc. CHROMA is a registered trademark of Chroma Inc., used here only to describe compatibility.
