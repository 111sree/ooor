#    OOOR: OpenObject On Ruby
#    Copyright (C) 2009-2014 Akretion LTDA (<http://www.akretion.com>).
#    Author: Raphaël Valyi
#    Licensed under the MIT license, see MIT-LICENSE file

require 'active_support/core_ext/module/delegation.rb'
require 'active_model/attribute_methods'
require 'active_model/dirty'
require 'ooor/reflection'
require 'ooor/reflection_ooor'
require 'ooor/errors'

module Ooor

  # meta data shared across sessions, a cache of the data in ir_model in OpenERP.
  # reused accross workers in a multi-process web app (via memcache for instance).
  class ModelTemplate

    TEMPLATE_PROPERTIES = [:name, :openerp_id, :info, :access_ids, :description,
      :openerp_model, :field_ids, :state, :fields,
      :many2one_associations, :one2many_associations, :many2many_associations,
      :polymorphic_m2o_associations, :associations_keys,
      :associations, :columns]

      attr_accessor *TEMPLATE_PROPERTIES, :columns_hash
  end

  # the base class for proxies to OpenERP objects
  class Base < Ooor::MiniActiveResource
    include Naming, TypeCasting, Serialization, ReflectionOoor, Reflection
    include Associations, Report, FinderMethods, FieldMethods

    # ********************** class methods ************************************
    class << self

      attr_accessor  :name, :connection, :t, :scope_prefix #template
      delegate *ModelTemplate::TEMPLATE_PROPERTIES, to: :t

      # ******************** remote communication *****************************

      def create(attributes = {}, context={}, default_get_list=false, reload=true)
        self.new(attributes, default_get_list, context).tap { |resource| resource.save(context, reload) }
      end

      #OpenERP search method
      def search(domain=[], offset=0, limit=false, order=false, context={}, count=false)
        rpc_execute(:search, to_openerp_domain(domain), offset, limit, order, context, count)
      end

      def name_search(name='', domain=[], operator='ilike', context={}, limit=100)
        rpc_execute(:name_search, name, to_openerp_domain(domain), operator, context, limit)
      end

      def rpc_execute(method, *args)
        object_service(:execute, openerp_model, method, *args)
      end

      def rpc_exec_workflow(action, *args)
        object_service(:exec_workflow, openerp_model, action, *args)
      end

      def object_service(service, obj, method, *args)
        reload_fields_definition(false)
        cast_answer_to_ruby!(connection.object.object_service(service, obj, method, *cast_request_to_openerp(args)))
      end

      def method_missing(method_symbol, *args)
        raise RuntimeError.new("Invalid RPC method:  #{method_symbol}") if [:type!, :allowed!].index(method_symbol)
        self.rpc_execute(method_symbol.to_s, *args)
      end

      # ******************** AREL Minimal implementation ***********************

      def relation(context={}); @relation ||= Relation.new(self, context); end #TODO template
      def scoped(context={}); relation(context); end
      def where(opts, *rest); relation.where(opts, *rest); end
      def all(*args); relation.all(*args); end
      def limit(value); relation.limit(value); end
      def order(value); relation.order(value); end
      def offset(value); relation.offset(value); end
      def first(*args); relation.first(*args); end
      def last(*args); relation.last(*args); end
      
      def logger; Ooor.logger; end

    end

    self.name = "Base"

    # ********************** instance methods **********************************

    attr_accessor :associations, :loaded_associations, :ir_model_data_id, :object_session

    include Persistence, Callbacks, ActiveModel::Dirty

    def rpc_execute(method, *args)
      args += [self.class.connection.connection_session.merge(object_session)] unless args[-1].is_a? Hash
      self.class.object_service(:execute, self.class.openerp_model, method, *args)
    end

    #Generic OpenERP rpc method call
    def call(method, *args) rpc_execute(method, *args) end

    #Generic OpenERP on_change method
    def on_change(on_change_method, field_name, field_value, *args)
      # NOTE: OpenERP doesn't accept context systematically in on_change events unfortunately
      ids = self.id ? [id] : []
      result = self.class.object_service(:execute, self.class.openerp_model, on_change_method, ids, *args)
      load_on_change_result(result, field_name, field_value)
    end

    #wrapper for OpenERP exec_workflow Business Process Management engine
    def wkf_action(action, context={}, reload=true)
      self.class.object_service(:exec_workflow, self.class.openerp_model, action, self.id, object_session)
      reload_fields(context) if reload
    end

    #Add get_report_data to obtain [report["result"],report["format]] of a concrete openERP Object
    def get_report_data(report_name, report_type="pdf", context={})
      self.class.get_report_data(report_name, [self.id], report_type, context)
    end

    def type() method_missing(:type) end #skips deprecated Object#type method

    private

    # Ruby 1.9.compat, See also http://tenderlovemaking.com/2011/06/28/til-its-ok-to-return-nil-from-to_ary/
    def to_ary; nil; end # :nodoc:

  end
end
