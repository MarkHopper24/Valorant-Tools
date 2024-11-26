# Valorant-Tools
This repository contains the source code, templates, and setup instructions for sending Valorant account game data to your TRMNL device using PowerShell and GitHub Actions.

![image](https://github.com/user-attachments/assets/d6207f75-9b81-4197-945d-f605eb43b67c)


## TRMNL Plugin Setup Instructions

### Prerequisites
- A TRMNL device (https://usetrmnl.com)
- TRMNL Private Plugin Id (https://help.usetrmnl.com/en/articles/9510536-private-plugins)
- API Key from HenrikDev Unofficial Valorant API (https://github.com/Henrik-3/unofficial-valorant-api)
- A fork of this repository

### Create a TRMNL private plugin
1. Create a webhook TRMNL private plugin using the TRMNL documentation (https://help.usetrmnl.com/en/articles/9510536-private-plugins)
2. Note down the Plugin ID provided by TRMNL. This will be used as a repository secret later.
3. Copy and paste the content in .\TRML\Template.html as your markdown.

### Configuring Secrets and Variables for GitHub Actions
1. Go to your forked repository.
2. Navigate to Settings > Secrets and variables > Actions.
3. Add the following secrets:
    - **ValorantKey**: Your HenrikDev Valorant API key.
    - **TRMNL_PLUGIN_ID1**: Your TRMNL Plugin ID.
    - **TRMNL_PLUGIN_ID2**: Your second TRMNL Plugin ID. (Optional)
4. Add the following variables:
    - **VALORANT_USERNAME1**: Your Valorant account username.
    - **VALORANT_TAGLINE1**: Your Valorant account tagline.
    - **VALORANT_USERNAME2**: Your second Valorant account username. (Optional)
    - **VALORANT_TAGLINE2**: Your second Valorant account tagline. (Optional)

### Enabling GitHub Actions Workflows
1. Go to your forked repository on GitHub.
2. Navigate to the Actions tab.
3. You will see a list of workflows defined in the repository. Click on the workflow you want to enable (e.g., ValorantTrackerUpdater.yml).
4. If the workflow is disabled, you will see a banner at the top of the page with an option to enable it. Click on "Enable workflow".
6. The workflow is now enabled and will run according to its defined schedule or when manually triggered. By default, it is set to run hourly from 6PM-2AM CST every day. Modify the cron in the schedule property to your liking.

After enabling the plugin on your TRMNL, your GitHub Actions configuration should now run the script as scheduled, and you can run the script on-demand. Once the script is run, your TRMNL plugin should show your updated stats during it's next refresh. 

![image](https://github.com/user-attachments/assets/ff99dc49-dc2e-4a9b-8b21-a3566a7e5a70)


### Script Description
The purpose of the [TRMNL/Trmnl_ValorantTracker.ps1](TRMNL/Trmnl_ValorantTracker.ps1) script is to fetch and process Valorant game statistics for specific users and send this data to the TRMNL platform. Here's a breakdown of its functionality:

1. **Parameters**: The script accepts several parameters, including `TrmnlPluginId`, `APIKey`, `username`, `tagline`, and an optional `region`.

2. **Headers**: It sets up authorization headers using the provided API key.

3. **Functions**:
   - `Get-AccountData`: Fetches account data for a given username and tagline.
   - `Get-MatchHistory`: Retrieves the match history for a user.
   - `Get-MatchDetails`: Fetches detailed information about a specific match.
   - `Get-MMRR`: Retrieves the MMR (Matchmaking Rating) data for a user.
   - `Get-CareerStats`: Calculates career statistics, including total games, wins, win rate, peak rating, and current rating.
   - `Get-LastMatches`: Processes the match history to extract relevant match details.
   - `New-TrmnlRequestBody`: Constructs the request body with match details and career statistics.
   - `Invoke-TrmnlPostRequest`: Sends the constructed data to the TRMNL platform via a POST request.

4. **Execution**: The script constructs the request body using `New-TrmnlRequestBody` and sends it to the TRMNL platform using `Invoke-TrmnlPostRequest`. This script can also be run manually by specifying downloading it and running using the required parameters above.

This script is used to automate the process of collecting and sending Valorant game statistics to the TRMNL platform for further analysis or display.

### Running the Script Manually
To run the script, use the following command:
```pwsh
.\Trmnl_ValorantTracker.ps1 -TrmnlPluginId "<YourPluginId>" -APIKey "<YourAPIKey>" -username "<YourUsername>" -tagline "<YourTagline>" -region "<Default 'na'>"
```

### YAML Description
The purpose of the `.github/workflows/ValorantTrackerUpdater.yml` GitHub Actions workflow is to automate the process of running the `Trmnl_ValorantTracker.ps1` PowerShell script at scheduled intervals and on-demand. This script fetches and processes Valorant game statistics for specific users and sends this data to the TRMNL platform. Here's a breakdown of its functionality:

1. **Environment Variables**:
   - `valorant_api_key`: API key for accessing the Valorant API.
   - `trmnl_plugin_id1` and `trmnl_plugin_id2`: Plugin IDs for the TRMNL platform.
   - `valorant_username1` and `valorant_username2`: Usernames for the Valorant accounts.
   - `valorant_tagline1` and `valorant_tagline2`: Taglines for the Valorant accounts.

2. **Triggers**:
   - `schedule`: Runs the workflow at specified times (hourly between 23:00 and 07:00 UTC).
   - `workflow_dispatch`: Allows the workflow to be manually triggered.

3. **Jobs**:
   - `run-script`: The job that runs the PowerShell script.
     - `runs-on: windows-latest`: Specifies the runner environment.
     - `steps`:
       - `Checkout repository`: Checks out the repository to the runner.
       - `Run PowerShell script for user 1`: Executes the `Trmnl_ValorantTracker.ps1` script for the first set of user credentials and plugin ID.
       - `Run PowerShell script for user 2`: Executes the `Trmnl_ValorantTracker.ps1` script for the second set of user credentials and plugin ID (if provided).

This workflow ensures that the Valorant game statistics are regularly updated and sent to the TRMNL platform without manual intervention.

## Discord Bot Setup Instruction
*Coming soon
