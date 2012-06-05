require_dependency 'repositories_controller'

module ScmRepositoriesControllerPatch

    def self.included(base)
        base.extend(ClassMethods)
        base.send(:include, InstanceMethods)
        base.class_eval do
            unloadable
            before_filter :delete_scm, :only => :destroy

            alias_method_chain :destroy, :confirmation

            if Project.method_defined?(:repositories)
                alias_method :create, :create_with_add
            else
                alias_method :edit, :edit_with_add
            end
        end
    end

    module ClassMethods
    end

    module InstanceMethods

        def delete_scm
            if @repository.created_with_scm && ScmConfig['deny_delete']
                Rails.logger.info "Deletion denied: #{@repository.root_url}"
                render_403
            end
        end

        # Redmine >= 1.4.x
        if Project.method_defined?(:repositories)

            # Original function
            #def create
            #    @repository = Repository.factory(params[:repository_scm], params[:repository])
            #    @repository.project = @project
            #    if request.post? && @repository.save
            #        redirect_to(settings_project_path(@project, :tab => 'repositories'))
            #    else
            #        render(:action => 'new')
            #    end
            #end

            def create_with_add
                @repository = Repository.factory(params[:repository_scm], params[:repository])
                if @repository
                    @repository.project = @project

                    if @repository.valid? && params[:operation].present? && params[:operation] == 'add'
                        if !ScmConfig['max_repos'] || ScmConfig['max_repos'].to_i == 0 || @project.repositories.size < ScmConfig['max_repos'].to_i
                            scm_create_repository(@repository, params[:repository_scm], params[:repository]['url'])
                        else
                            @repository.errors.add(:base, :scm_repositories_maximum_count_exceeded, :max => ScmConfig['max_repos'].to_i)
                        end
                    end

                    if !ScmConfig['allow_add_local'] && request.post? && @repository.errors.empty? && !@repository.created_with_scm &&
                        params[:repository]['url'] =~ %r{^(file://|([a-z]:)?\.*[\\/])}i
                        @repository.errors.add(:base, :scm_local_repositories_denied)
                    end

                    if request.post? && @repository.errors.empty? && @repository.save
                        redirect_to(settings_project_path(@project, :tab => 'repositories'))
                    else
                        render(:action => 'new')
                    end
                else
                    render(:action => 'new')
                end
            end

        # Redmine < 1.4.x or ChiliProject
        else

            # Original function
            #def edit
            #    @repository = @project.repository
            #    if !@repository && !params[:repository_scm].blank?
            #        @repository = Repository.factory(params[:repository_scm])
            #        @repository.project = @project if @repository
            #    end
            #    if request.post? && @repository
            #        p1 = params[:repository]
            #        p       = {}
            #        p_extra = {}
            #        p1.each do |k, v|
            #            if k =~ /^extra_/
            #                p_extra[k] = v
            #            else
            #                p[k] = v
            #            end
            #        end
            #        @repository.attributes = p
            #        @repository.merge_extra_info(p_extra)
            #        @repository.save
            #    end
            #    render(:update) do |page|
            #        page.replace_html("tab-content-repository", :partial => 'projects/settings/repository')
            #        if @repository && !@project.repository
            #            @project.reload
            #            page.replace_html("main-menu", render_main_menu(@project))
            #        end
            #    end
            #end

            def edit_with_add
                @repository = @project.repository
                if !@repository && !params[:repository_scm].blank?
                    @repository = Repository.factory(params[:repository_scm])
                    @repository.project = @project if @repository
                end

                if request.post? && @repository
                    attributes = params[:repository]
                    attrs = {}
                    extra = {}
                    attributes.each do |name, value|
                        if name =~ %r{^extra_}
                            extra[name] = value
                        else
                            attrs[name] = value
                        end
                    end
                    @repository.attributes = attrs

                    if @repository.valid? && params[:operation].present? && params[:operation] == 'add'
                        scm_create_repository(@repository, params[:repository_scm], attrs['url']) if attrs
                    end

                    if !ScmConfig['allow_add_local'] && @repository.errors.empty? && !@repository.created_with_scm &&
                        attrs['url'] =~ %r{^(file://|([a-z]:)?\.*[\\/])}i
                        @repository.errors.add(:base, :scm_local_repositories_denied)
                    end

                    if @repository.errors.empty?
                        @repository.merge_extra_info(extra) if @repository.respond_to?(:merge_extra_info)
                        @repository.save
                    end
                end

                render(:update) do |page|
                    page.replace_html("tab-content-repository", :partial => 'projects/settings/repository')
                    if @repository && !@project.repository
                        @project.reload
                        page.replace_html("main-menu", render_main_menu(@project))
                    end
                end
            end

        end

        def destroy_with_confirmation
            if @repository.created_with_scm
                if params[:confirm]
                    unless params[:confirm_with_scm]
                        @repository.created_with_scm = false
                    end

                    destroy_without_confirmation
                end
            else
                destroy_without_confirmation
            end
        end

    private

        def scm_create_repository(repository, scm, url)
            interface = Object.const_get("#{scm}Creator")

            name = interface.repository_name(url)
            if name
                path = interface.path(name)
                if File.directory?(path)
                    repository.errors.add(:url, :already_exists)
                else
                    Rails.logger.info "Creating reporitory: #{path}"
                    interface.execute(ScmConfig['pre_create'], path, @project) if ScmConfig['pre_create']
                    if interface.create_repository(path)
                        interface.execute(ScmConfig['post_create'], path, @project) if ScmConfig['post_create']
                        repository.created_with_scm = true
                        unless interface.copy_hooks(path)
                            Rails.logger.warn "Hooks copy failed"
                        end
                    else
                        Rails.logger.error "Repository creation failed"
                    end
                end

                repository.root_url = interface.access_root_url(path)
                repository.url = interface.access_url(path)

                if !interface.repository_name_equal?(name, @project.identifier)
                    flash[:warning] = l(:text_cannot_be_used_redmine_auth)
                end
            else
                repository.errors.add(:url, :should_be_of_format_local, :format => interface.repository_format)
            end

            # Otherwise input field will be disabled
            if repository.errors.any?
                repository.root_url = nil
                repository.url = nil
            end

        rescue NameError
            Rails.logger.error "Can't find interface for #{scm}."
            repository.errors.add(:base, :scm_not_supported)
        end

    end

end
