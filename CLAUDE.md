SYSTEM CONTEXT:
You are an expert DevOps engineer refactoring a local Windows PowerShell provisioning script into a clean, open-source repository configuration. The utility uses the native Oracle Cloud Infrastructure (OCI) CLI to automate shape deployments.

CURRENT WORKING BASE CODE:
The logic core is currently configured inside an active Windows Scheduled Task running under 'NT AUTHORITY\SYSTEM' to survive hardware power drops. The execution loop catches non-success states, implements automated exception handling, and calculates a dynamic randomized jitter backoff (60s base + random pad) to manage data center resource exhaustion gracefully.

REFACTORING TARGETS:
1. DECOUPLE ENVIRONMENTAL VARIABLES: Extract all infrastructure parameters (CompartmentId, SubnetId, ImageId, AvailabilityDomain, SshKeyPath, and NtfyTopic) entirely out of the script logic core.
2. SCHEMA DESIGN: Create a 'config.json.example' structural blueprint for public distribution.
3. CONTEXT PARSING: Update the main script to look for a local 'config.json' file using '$PSScriptRoot'. Implement an explicit evaluation gate that terminates execution with a clean error message if the local JSON configuration file is absent.
4. INTEGRATE NTFY WEBHOOKS: Implement a clean native 'Invoke-RestMethod' payload inside the true success condition that fires a push notification to an unauthenticated ntfy.sh topic string specified in the JSON config. Ensure the 'Uri' properly parses the string without dynamic variable collisions (avoid stray '$' prefix inside the string path).
5. VALIDATION HARDENING: Ensure the loop breaks ONLY when the OCI CLI return stream contains a valid structural confirmation instance string ('ocid1.instance.oc1'). Any other return token or status error code must trigger the 'catch' block backoff window.

TASK:
Generate the production-ready code files matching these design rules. Keep the code heavily commented using standard enterprise documentation patterns to make it clear, readable, and portfolio-ready.