package manifests

import (
	"encoding/base64"
	"path/filepath"

	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/ghodss/yaml"
	"github.com/pkg/errors"

	"github.com/gophercloud/utils/openstack/clientconfig"
	"github.com/openshift/installer/pkg/asset"
	"github.com/openshift/installer/pkg/asset/installconfig"
	"github.com/openshift/installer/pkg/asset/machines"
	"github.com/openshift/installer/pkg/asset/templates/content/tectonic"
	"github.com/openshift/installer/pkg/asset/tls"
)

const (
	tectonicManifestDir = "tectonic"
)

var (
	tectonicConfigPath = filepath.Join(tectonicManifestDir, "00_cluster-config.yaml")

	_ asset.WritableAsset = (*Tectonic)(nil)
)

// Tectonic generates the dependent resource manifests for tectonic (as against bootkube)
type Tectonic struct {
	TectonicConfig *configurationObject
	FileList       []*asset.File
}

// Name returns a human friendly name for the operator
func (t *Tectonic) Name() string {
	return "Tectonic Manifests"
}

// Dependencies returns all of the dependencies directly needed by the
// Tectonic asset
func (t *Tectonic) Dependencies() []asset.Asset {
	return []asset.Asset{
		&installconfig.InstallConfig{},
		&tls.IngressCertKey{},
		&tls.KubeCA{},
		&ClusterK8sIO{},
		&machines.Worker{},
		&machines.Master{},
		&kubeAddonOperator{},

		&tectonic.BindingDiscovery{},
		&tectonic.AppVersionKubeAddon{},
		&tectonic.KubeAddonOperator{},
		&tectonic.RoleAdmin{},
		&tectonic.RoleUser{},
		&tectonic.BindingAdmin{},
		&tectonic.PullTectonicSystem{},
		&tectonic.CloudCredsSecret{},
		&tectonic.RoleCloudCredsSecretReader{},
	}
}

// Generate generates the respective operator config.yml files
func (t *Tectonic) Generate(dependencies asset.Parents) error {
	installConfig := &installconfig.InstallConfig{}
	clusterk8sio := &ClusterK8sIO{}
	worker := &machines.Worker{}
	master := &machines.Master{}
	addon := &kubeAddonOperator{}
	dependencies.Get(installConfig, clusterk8sio, worker, master, addon)
	var cloudCreds cloudCredsSecretData
	platform := installConfig.Config.Platform.Name()
	switch platform {
	case "aws":
		ssn := session.Must(session.NewSessionWithOptions(session.Options{
			SharedConfigState: session.SharedConfigEnable,
		}))
		creds, err := ssn.Config.Credentials.Get()
		if err != nil {
			return err
		}
		cloudCreds = cloudCredsSecretData{
			AWS: &AwsCredsSecretData{
				Base64encodeAccessKeyID:     base64.StdEncoding.EncodeToString([]byte(creds.AccessKeyID)),
				Base64encodeSecretAccessKey: base64.StdEncoding.EncodeToString([]byte(creds.SecretAccessKey)),
			},
		}
	case "openstack":
		clouds, err := clientconfig.LoadCloudsYAML()
		if err != nil {
			return err
		}

		marshalled, err := yaml.Marshal(clouds)
		if err != nil {
			return err
		}

		credsEncoded := base64.StdEncoding.EncodeToString(marshalled)
		cloudCreds = cloudCredsSecretData{
			OpenStack: &OpenStackCredsSecretData{
				Base64encodeCloudCreds: credsEncoded,
			},
		}
	}

	templateData := &tectonicTemplateData{
		KubeAddonOperatorImage: "quay.io/coreos/kube-addon-operator-dev:70cae49142ff69e83ed7b41fa81a585b02cdea7d",
		PullSecret:             base64.StdEncoding.EncodeToString([]byte(installConfig.Config.PullSecret)),
		CloudCreds:             cloudCreds,
	}

	bindingDiscovery := &tectonic.BindingDiscovery{}
	appVersionKubeAddon := &tectonic.AppVersionKubeAddon{}
	kubeAddonOperator := &tectonic.KubeAddonOperator{}
	roleAdmin := &tectonic.RoleAdmin{}
	roleUser := &tectonic.RoleUser{}
	bindingAdmin := &tectonic.BindingAdmin{}
	pullTectonicSystem := &tectonic.PullTectonicSystem{}
	cloudCredsSecret := &tectonic.CloudCredsSecret{}
	roleCloudCredsSecretReader := &tectonic.RoleCloudCredsSecretReader{}
	dependencies.Get(
		bindingDiscovery,
		appVersionKubeAddon,
		kubeAddonOperator,
		roleAdmin,
		roleUser,
		bindingAdmin,
		pullTectonicSystem,
		cloudCredsSecret,
		roleCloudCredsSecretReader)
	assetData := map[string][]byte{
		"99_binding-discovery.yaml":                             []byte(bindingDiscovery.Files()[0].Data),
		"99_kube-addon-00-appversion.yaml":                      []byte(appVersionKubeAddon.Files()[0].Data),
		"99_kube-addon-01-operator.yaml":                        applyTemplateData(kubeAddonOperator.Files()[0].Data, templateData),
		"99_openshift-cluster-api_cluster.yaml":                 clusterk8sio.Raw,
		"99_openshift-cluster-api_master-machines.yaml":         master.MachinesRaw,
		"99_openshift-cluster-api_master-user-data-secret.yaml": master.UserDataSecretRaw,
		"99_openshift-cluster-api_worker-machineset.yaml":       worker.MachineSetRaw,
		"99_openshift-cluster-api_worker-user-data-secret.yaml": worker.UserDataSecretRaw,
		"99_role-admin.yaml":                                    []byte(roleAdmin.Files()[0].Data),
		"99_role-user.yaml":                                     []byte(roleUser.Files()[0].Data),
		"99_tectonic-system-00-binding-admin.yaml":              []byte(bindingAdmin.Files()[0].Data),
		"99_tectonic-system-02-pull.json":                       applyTemplateData(pullTectonicSystem.Files()[0].Data, templateData),
	}

	switch platform {
	case "aws", "openstack":
		assetData["99_cloud-creds-secret.yaml"] = applyTemplateData(cloudCredsSecret.Files()[0].Data, templateData)
		assetData["99_role-cloud-creds-secret-reader.yaml"] = applyTemplateData(roleCloudCredsSecretReader.Files()[0].Data, templateData)
	}

	// addon goes to openshift system
	t.TectonicConfig = configMap("tectonic-system", "cluster-config-v1", genericData{
		"addon-config": string(addon.Files()[0].Data),
	})
	tectonicConfigData, err := yaml.Marshal(t.TectonicConfig)
	if err != nil {
		return errors.Wrap(err, "failed to create tectonic-system/cluster-config-v1 configmap")
	}

	t.FileList = []*asset.File{
		{
			Filename: tectonicConfigPath,
			Data:     tectonicConfigData,
		},
	}
	for name, data := range assetData {
		t.FileList = append(t.FileList, &asset.File{
			Filename: filepath.Join(tectonicManifestDir, name),
			Data:     data,
		})
	}

	return nil
}

// Files returns the files generated by the asset.
func (t *Tectonic) Files() []*asset.File {
	return t.FileList
}

// Load returns the tectonic asset from disk.
func (t *Tectonic) Load(f asset.FileFetcher) (bool, error) {
	fileList, err := f.FetchByPattern(filepath.Join(tectonicManifestDir, "*"))
	if err != nil {
		return false, err
	}
	if len(fileList) == 0 {
		return false, nil
	}

	tectonicConfig := &configurationObject{}
	var found bool
	for _, file := range fileList {
		if file.Filename == tectonicConfigPath {
			if err := yaml.Unmarshal(file.Data, tectonicConfig); err != nil {
				return false, errors.Wrapf(err, "failed to unmarshal 00_cluster-config.yaml")
			}
			found = true
		}
	}

	if !found {
		return false, nil
	}

	t.FileList, t.TectonicConfig = fileList, tectonicConfig
	return true, nil
}
