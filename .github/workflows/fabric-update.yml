name: Update Fabric Workspace from Git

on:
  push:
    branches:
      - prod

jobs:
  update-fabric:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repo
        uses: actions/checkout@v4
        
      - name: Install Az PowerShell module
        shell: pwsh
        run: |
          Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
          Install-Module -Name Az -Repository PSGallery -Force -AllowClobber


      - name: Run Fabric update script
        shell: pwsh
        env:
          TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}
          SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
          CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
          CLIENT_SECRET: ${{ secrets.AZURE_CLIENT_SECRET }}
        run: |
          pwsh -File ./scripts/UpdateFromGit.ps1 `
            -workspaceName "DemoWS_Prod" `
            -principalType "ServicePrincipal" `
            -tenantId $env:TENANT_ID `
            -subscriptionId $env:SUBSCRIPTION_ID `
            -clientId $env:CLIENT_ID `
            -servicePrincipalSecret $env:CLIENT_SECRET
