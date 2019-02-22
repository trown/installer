package openstack

import (
	"fmt"

	"github.com/gophercloud/gophercloud/openstack/networking/v2/subnets"
	"github.com/gophercloud/gophercloud/pagination"
	"github.com/gophercloud/utils/openstack/clientconfig"
	openstackprovider "sigs.k8s.io/cluster-api-provider-openstack/pkg/apis/openstackproviderconfig/v1alpha1"
)

// GetNetworkNames gets the valid network names.
func GetNodesSubnet(cloud string, filter openstackprovider.Filter) (string, error) {
	opts := &clientconfig.ClientOpts{
		Cloud: cloud,
	}

	conn, err := clientconfig.NewServiceClient("network", opts)
	if err != nil {
		return "", err
	}

	listOpts := subnets.ListOpts{
		Name: filter.Name,
		Tags: filter.Tags,
	}
	pager := subnets.List(conn, listOpts)
	var uuid string
	err = pager.EachPage(func(page pagination.Page) (bool, error) {
		subnetList, err := subnets.ExtractSubnets(page)
		if err != nil {
			return false, err
		} else if len(subnetList) == 0 {
			return false, fmt.Errorf("No networks could be found with the filters provided")
		}

		uuid = subnetList[0].ID
		return true, nil
	})

	if err != nil {
		return "", err
	}

	return uuid, err
}
