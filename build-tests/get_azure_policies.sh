#!/bin/bash

# Define output file
OUTPUT_FILE="azure_policy_restrictions.md"

echo "# Azure Policy Restrictions" > $OUTPUT_FILE
echo "" >> $OUTPUT_FILE
echo "Generated on: $(date)" >> $OUTPUT_FILE
echo "" >> $OUTPUT_FILE

echo "## Active Policy Assignments" >> $OUTPUT_FILE
echo "" >> $OUTPUT_FILE
echo "| Display Name | Policy Definition ID | Enforcement Mode |" >> $OUTPUT_FILE
echo "|---|---|---|" >> $OUTPUT_FILE

# Get policy assignments and format as markdown table
az policy assignment list --query "[].{displayName:displayName, policyDefinitionId:policyDefinitionId, enforcementMode:enforcementMode}" -o tsv | while read -r displayName policyDefinitionId enforcementMode; do
    echo "| $displayName | \`$policyDefinitionId\` | $enforcementMode |" >> $OUTPUT_FILE
done

echo "" >> $OUTPUT_FILE
echo "## Detailed Policy Definitions" >> $OUTPUT_FILE
echo "" >> $OUTPUT_FILE

# Loop through assignments to get definitions
ASSIGNED_IDS=$(az policy assignment list --query "[].policyDefinitionId" -o tsv | sort | uniq)

for policyId in $ASSIGNED_IDS; do
    echo "### Policy ID: \`$policyId\`" >> $OUTPUT_FILE
    echo "" >> $OUTPUT_FILE
    
    DEFINITION=""
    
    if [[ "$policyId" == *"policySetDefinitions"* ]]; then
        # It's an initiative (Policy Set)
        echo "**Type:** Initiative (Policy Set)" >> $OUTPUT_FILE
        DEFINITION=$(az policy set-definition show --id "$policyId" --query "{displayName:displayName, description:description, parameters:parameters}" -o json 2>/dev/null)
    else
        # It's a single policy
        echo "**Type:** Policy Definition" >> $OUTPUT_FILE
        DEFINITION=$(az policy definition show --id "$policyId" --query "{displayName:displayName, description:description, parameters:parameters}" -o json 2>/dev/null)
    fi

    if [ -n "$DEFINITION" ]; then
        NAME=$(echo $DEFINITION | jq -r '.displayName')
        DESC=$(echo $DEFINITION | jq -r '.description')
        echo "**Name:** $NAME" >> $OUTPUT_FILE
        echo "" >> $OUTPUT_FILE
        echo "**Description:** $DESC" >> $OUTPUT_FILE
        echo "" >> $OUTPUT_FILE
    else
        echo "Could not retrieve definition details. (Check permissions or ID validity)" >> $OUTPUT_FILE
    fi
    echo "---" >> $OUTPUT_FILE
done

echo "Policy documentation generated in $OUTPUT_FILE"
