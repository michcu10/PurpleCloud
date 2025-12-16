#!/bin/bash
# PurpleCloud Zero Trust Lab Cleanup Script
# This script safely destroys all Terraform resources
# Usage: ./cleanup.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[-]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[*]${NC} $1"
}

# Function to check if terraform is installed
check_terraform() {
    if ! command -v terraform &> /dev/null; then
        print_error "Terraform is not installed. Please install Terraform first."
        exit 1
    fi
}

# Function to check if az CLI is installed
check_az_cli() {
    if ! command -v az &> /dev/null; then
        print_warning "Azure CLI not found. Orphaned resource cleanup will be skipped."
        return 1
    fi
    
    if ! az account show &> /dev/null; then
        print_warning "Not logged into Azure CLI. Run 'az login' first."
        return 1
    fi
    
    return 0
}

# Function to destroy a generator's resources
destroy_generator() {
    local generator_path=$1
    local generator_name=$(basename $generator_path)
    
    print_info "========================================"
    print_info "Cleaning up $generator_name..."
    print_info "========================================"
    
    if [ ! -d "$generator_path" ]; then
        print_warning "Directory not found: $generator_path"
        return
    fi
    
    cd "$generator_path"
    
    # Check if there are any .tf files
    if ! ls *.tf &> /dev/null; then
        print_warning "No Terraform files found in $generator_name, skipping..."
        cd - > /dev/null
        return
    fi
    
    # Check if terraform.tfstate exists
    if [ ! -f "terraform.tfstate" ]; then
        print_warning "No Terraform state found for $generator_name"
        read -p "Do you want to attempt to import existing state? (yes/no): " import_state
        if [ "$import_state" != "yes" ]; then
            print_info "Skipping $generator_name..."
            cd - > /dev/null
            return
        fi
    fi
    
    # Initialize Terraform
    print_status "Initializing Terraform..."
    if ! terraform init; then
        print_error "Failed to initialize Terraform for $generator_name"
        cd - > /dev/null
        return
    fi
    
    # Show what will be destroyed
    print_warning "The following resources will be destroyed:"
    terraform show
    
    echo ""
    read -p "Proceed with destroying $generator_name resources? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "Skipping $generator_name..."
        cd - > /dev/null
        return
    fi
    
    # Destroy resources
    print_status "Destroying $generator_name resources..."
    if terraform destroy -auto-approve; then
        print_status "$generator_name cleanup complete!"
    else
        print_error "Failed to destroy some $generator_name resources"
        print_warning "You may need to manually delete resources in Azure Portal"
    fi
    
    cd - > /dev/null
}

# Function to clean up orphaned Azure resources
cleanup_orphaned_resources() {
    if ! check_az_cli; then
        return
    fi
    
    print_info "========================================"
    print_info "Checking for orphaned Azure resources..."
    print_info "========================================"
    
    # Find PurpleCloud resource groups
    print_status "Searching for PurpleCloud resource groups..."
    orphaned_rgs=$(az group list --query "[?starts_with(name, 'PurpleCloud') || contains(name, 'ZeroTrust')].name" -o tsv)
    
    if [ -z "$orphaned_rgs" ]; then
        print_status "No orphaned resource groups found."
        return
    fi
    
    print_warning "Found the following resource groups:"
    echo "$orphaned_rgs"
    echo ""
    
    read -p "Delete these resource groups? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        print_info "Skipping orphaned resource cleanup"
        return
    fi
    
    echo "$orphaned_rgs" | while read rg; do
        if [ -n "$rg" ]; then
            print_status "Deleting resource group: $rg"
            az group delete --name "$rg" --yes --no-wait || print_warning "Failed to delete $rg"
        fi
    done
    
    print_status "Resource group deletion initiated (running in background)"
    print_info "Use 'az group list' to check deletion progress"
}

# Function to delete Terraform state files
delete_terraform_state() {
    print_info "========================================"
    print_warning "Delete Terraform State Files"
    print_info "========================================"
    print_warning "This will delete all Terraform state files!"
    print_warning "You will NOT be able to manage resources with Terraform after this."
    echo ""
    read -p "Are you sure? Type 'DELETE' to confirm: " confirm
    
    if [ "$confirm" != "DELETE" ]; then
        print_info "Skipping state file deletion"
        return
    fi
    
    print_status "Deleting Terraform state files..."
    find generators/ -name "terraform.tfstate*" -delete 2>/dev/null || true
    find generators/ -type d -name ".terraform" -exec rm -rf {} + 2>/dev/null || true
    find generators/ -name "*.tfplan" -delete 2>/dev/null || true
    print_status "Terraform state files deleted!"
}

# Function to show main menu
show_menu() {
    echo ""
    echo "========================================="
    echo "  PurpleCloud Zero Trust Lab Cleanup"
    echo "========================================="
    echo "1. Clean up Azure AD resources"
    echo "2. Clean up Managed Identity resources"
    echo "3. Clean up Storage resources"
    echo "4. Clean up ALL resources (recommended)"
    echo "5. Check for orphaned Azure resources"
    echo "6. Delete Terraform state files"
    echo "7. Full cleanup (destroy + orphaned + state)"
    echo "8. Exit"
    echo "========================================="
}

# Main script
main() {
    check_terraform
    
    print_info "PurpleCloud Zero Trust Lab Cleanup Script"
    print_info "Location: $(pwd)"
    
    while true; do
        show_menu
        read -p "Select an option (1-8): " choice
        
        case $choice in
            1)
                destroy_generator "generators/azure_ad"
                ;;
            2)
                destroy_generator "generators/managed_identity"
                ;;
            3)
                destroy_generator "generators/storage"
                ;;
            4)
                print_warning "This will destroy ALL PurpleCloud resources!"
                read -p "Are you sure? Type 'yes' to confirm: " confirm
                if [ "$confirm" == "yes" ]; then
                    destroy_generator "generators/azure_ad"
                    destroy_generator "generators/managed_identity"
                    destroy_generator "generators/storage"
                    print_status "All resources destroyed!"
                else
                    print_info "Cancelled"
                fi
                ;;
            5)
                cleanup_orphaned_resources
                ;;
            6)
                delete_terraform_state
                ;;
            7)
                print_warning "========================================="
                print_warning "FULL CLEANUP - This will:"
                print_warning "  - Destroy all Terraform resources"
                print_warning "  - Delete orphaned Azure resource groups"
                print_warning "  - Remove all Terraform state files"
                print_warning "========================================="
                read -p "Type 'DESTROY' to confirm: " confirm
                
                if [ "$confirm" == "DESTROY" ]; then
                    print_status "Starting full cleanup..."
                    destroy_generator "generators/azure_ad"
                    destroy_generator "generators/managed_identity"
                    destroy_generator "generators/storage"
                    cleanup_orphaned_resources
                    
                    read -p "Also delete Terraform state files? (yes/no): " delete_state
                    if [ "$delete_state" == "yes" ]; then
                        delete_terraform_state
                    fi
                    
                    print_status "========================================="
                    print_status "Full cleanup complete!"
                    print_status "========================================="
                else
                    print_error "Cleanup cancelled"
                fi
                ;;
            8)
                print_status "Exiting..."
                exit 0
                ;;
            *)
                print_error "Invalid option. Please select 1-8."
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

# Run main function
main
