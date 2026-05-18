// Copyright 2021 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package driver_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	cosi "sigs.k8s.io/container-object-storage-interface/proto"
	"sigs.k8s.io/cosi-driver-sample/pkg/driver"
)

func TestIdentityServer_DriverGetInfo(t *testing.T) {
	for _, tc := range []struct {
		name              string
		driverName        string
		expectedError     error
		expectedProtocols []*cosi.ObjectProtocol
	}{
		{
			name:              "success",
			driverName:        "sample.objectstorage.x-k8s.io",
			expectedProtocols: []*cosi.ObjectProtocol{{Type: cosi.ObjectProtocol_S3}},
		},
		{
			name:              "empty driver name",
			driverName:        "",
			expectedError:     driver.ErrEmptyDriverName,
			expectedProtocols: nil,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := driver.IdentityServer{
				DriverName: tc.driverName,
			}

			actual, err := srv.DriverGetInfo(t.Context(), &cosi.DriverGetInfoRequest{})

			if tc.expectedError != nil {
				require.Error(t, err)
				assert.Contains(t, err.Error(), tc.expectedError.Error())
				return
			}

			require.NoError(t, err)
			assert.Equal(t, tc.driverName, actual.Name)
			assert.Equal(t, tc.expectedProtocols, actual.SupportedProtocols)
		})
	}
}
