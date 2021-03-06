require 'spec_helper'
require 'actions/app_start'

module VCAP::CloudController
  RSpec.describe AppStart do
    let(:user_guid) { 'some-guid' }
    let(:user_email) { '1@2.3' }
    let(:user_audit_info) { UserAuditInfo.new(user_email: user_email, user_guid: user_guid) }

    describe '#start' do
      let(:environment_variables) { { 'FOO' => 'bar' } }

      context 'when the app has a docker lifecycle' do
        let(:app) do
          AppModel.make(
            :docker,
            desired_state:         'STOPPED',
            environment_variables: environment_variables
          )
        end
        let(:package) { PackageModel.make(:docker, app: app, state: PackageModel::READY_STATE) }
        let!(:droplet) { DropletModel.make(:docker, app: app, package: package, state: DropletModel::STAGED_STATE, docker_receipt_image: package.image) }
        let!(:process1) { ProcessModel.make(:process, state: 'STOPPED', app: app) }
        let!(:process2) { ProcessModel.make(:process, state: 'STOPPED', app: app) }

        before do
          app.update(droplet: droplet)
          VCAP::CloudController::FeatureFlag.make(name: 'diego_docker', enabled: true, error_message: nil)
        end

        it 'starts the app' do
          AppStart.start(app: app, user_audit_info: user_audit_info)
          expect(app.desired_state).to eq('STARTED')
        end

        it 'sets the docker image on the process' do
          AppStart.start(app: app, user_audit_info: user_audit_info)

          process1.reload
          expect(process1.docker_image).to eq(droplet.docker_receipt_image)
        end
      end

      context 'when the app has a buildpack lifecycle' do
        let(:app) do
          AppModel.make(:buildpack,
            desired_state:         'STOPPED',
            environment_variables: environment_variables)
        end
        let!(:droplet) { DropletModel.make(app: app) }
        let!(:process1) { ProcessModel.make(:process, state: 'STOPPED', app: app) }
        let!(:process2) { ProcessModel.make(:process, state: 'STOPPED', app: app) }

        before do
          app.update(droplet: droplet)
        end

        it 'sets the desired state on the app' do
          AppStart.start(app: app, user_audit_info: user_audit_info)
          expect(app.desired_state).to eq('STARTED')
        end

        it 'creates an audit event' do
          expect_any_instance_of(Repositories::AppEventRepository).to receive(:record_app_start).with(
            app,
            user_audit_info,
          )

          AppStart.start(app: app, user_audit_info: user_audit_info)
        end

        context 'when the app is invalid' do
          before do
            allow_any_instance_of(AppModel).to receive(:update).and_raise(Sequel::ValidationFailed.new('some message'))
          end

          it 'raises a InvalidApp exception' do
            expect {
              AppStart.start(app: app, user_audit_info: user_audit_info)
            }.to raise_error(AppStart::InvalidApp, 'some message')
          end
        end

        context 'and the droplet has a package' do
          let!(:droplet) do
            DropletModel.make(
              app:     app,
              package: package,
              state:   DropletModel::STAGED_STATE,
            )
          end
          let(:package) { PackageModel.make(app: app, package_hash: 'some-awesome-thing', state: PackageModel::READY_STATE) }

          it 'sets the package hash correctly on the process' do
            AppStart.start(app: app, user_audit_info: user_audit_info)

            process1.reload
            expect(process1.package_hash).to eq(package.package_hash)
            expect(process1.package_state).to eq('STAGED')

            process2.reload
            expect(process2.package_hash).to eq(package.package_hash)
            expect(process2.package_state).to eq('STAGED')
          end
        end
      end

      context 'when the app has two associated droplets' do
        let(:app) { AppModel.make(:buildpack) }
        let!(:web_process) { ProcessModel.make(app: app, type: 'web', revision: revisionA) }
        let!(:worker_process) { ProcessModel.make(app: app, type: 'worker', revision: revisionA) }
        let(:package) { PackageModel.make(app: app, state: PackageModel::READY_STATE) }
        let!(:dropletA) { DropletModel.make(app: app, package: package, state: DropletModel::STAGED_STATE) }
        let!(:dropletB) { DropletModel.make(app: app, package: package, state: DropletModel::STAGED_STATE) }
        let!(:revisionA) { RevisionModel.make(app: app, droplet_guid: dropletA.guid) }
        let!(:new_revision_number) { revisionA.version + 1 }

        it 'creates a new revision when it switches droplets and revisions are enabled' do
          app.update(revisions_enabled: true)
          app.update(droplet: dropletB)
          expect do
            AppStart.start(app: app, user_audit_info: user_audit_info)
          end.to change { RevisionModel.count }.by(1)
          last_revision = RevisionModel.last
          expect(last_revision.version).to eq(new_revision_number)
        end

        it 'does not create a new revision if it was already started' do
          app.update(desired_state: ProcessModel::STARTED)
          app.update(revisions_enabled: true)
          app.update(droplet: dropletB)
          expect do
            AppStart.start(app: app, user_audit_info: user_audit_info)
          end.not_to change { RevisionModel.count }
        end

        it 'does not create a new revision if the droplet did not change' do
          app.update(revisions_enabled: true)
          app.update(droplet: dropletA)
          expect do
            AppStart.start(app: app, user_audit_info: user_audit_info)
          end.to change { RevisionModel.count }.by(0)
          expect(RevisionModel.last.version).to eq(revisionA.version)
          expect(web_process.reload.revision).to eq(revisionA)
          expect(worker_process.reload.revision).to eq(revisionA)
        end

        it 'does not create a new revision if revisions are disabled' do
          app.update(revisions_enabled: false)
          app.update(droplet: dropletB)
          expect do
            AppStart.start(app: app, user_audit_info: user_audit_info)
          end.to change { RevisionModel.count }.by(0)
          expect(RevisionModel.last.version).to eq(revisionA.version)
          expect(web_process.reload.revision).to eq(revisionA)
          expect(worker_process.reload.revision).to eq(revisionA)
        end
      end

      describe '#start_without_event' do
        let(:app) { AppModel.make(:buildpack, desired_state: 'STOPPED') }

        it 'sets the desired state on the app' do
          AppStart.start_without_event(app)
          expect(app.desired_state).to eq('STARTED')
        end

        it 'does not create an audit event' do
          expect_any_instance_of(Repositories::AppEventRepository).not_to receive(:record_app_start)
          AppStart.start_without_event(app)
        end
      end
    end
  end
end
