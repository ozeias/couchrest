require 'time'
require File.join(File.dirname(__FILE__), '..', 'more', 'property')

class Time                       
  # returns a local time value much faster than Time.parse
  def self.mktime_with_offset(string)
    string =~ /(\d{4})\/(\d{2})\/(\d{2}) (\d{2}):(\d{2}):(\d{2}) ([\+\-])(\d{2})/
    # $1 = year
    # $2 = month
    # $3 = day
    # $4 = hours
    # $5 = minutes
    # $6 = seconds
    # $7 = time zone direction
    # $8 = tz difference
    # utc time with wrong TZ info: 
    time = mktime($1, RFC2822_MONTH_NAME[$2.to_i - 1], $3, $4, $5, $6, $7)
    tz_difference = ("#{$7 == '-' ? '+' : '-'}#{$8}".to_i * 3600)
    tz_offset = zone_offset(time.zone) || 0
    time + tz_difference + tz_offset
  end 
end

module CouchRest
  module Mixins
    module Properties
      
      class IncludeError < StandardError; end
      
      def self.included(base)
        base.class_eval <<-EOS, __FILE__, __LINE__
            extlib_inheritable_accessor(:properties) unless self.respond_to?(:properties)
            self.properties ||= []
        EOS
        base.extend(ClassMethods)
        raise CouchRest::Mixins::Properties::IncludeError, "You can only mixin Properties in a class responding to [] and []=, if you tried to mixin CastedModel, make sure your class inherits from Hash or responds to the proper methods" unless (base.new.respond_to?(:[]) && base.new.respond_to?(:[]=))
      end
      
      def apply_defaults
        return if self.respond_to?(:new_document?) && (new_document? == false)
        return unless self.class.respond_to?(:properties) 
        return if self.class.properties.empty?
        # TODO: cache the default object
        self.class.properties.each do |property|
          key = property.name.to_s
          # let's make sure we have a default
          unless property.default.nil?
              if property.default.class == Proc
                self[key] = property.default.call
              else
                self[key] = Marshal.load(Marshal.dump(property.default))
              end
            end
        end
      end
      
      def cast_keys
        return unless self.class.properties
        self.class.properties.each do |property|
          next unless property.casted
          key = self.has_key?(property.name) ? property.name : property.name.to_sym
          # Don't cast the property unless it has a value
          next unless self[key]   
          target = property.type
          if target.is_a?(Array)
            klass = ::CouchRest.constantize(target[0])
            self[property.name] = self[key].collect do |value|
              # Auto parse Time objects
              obj = ( (property.init_method == 'new') && klass == Time) ? Time.parse(value) : klass.send(property.init_method, value)
              obj.casted_by = self if obj.respond_to?(:casted_by)
              obj 
            end
          else
            # Auto parse Time objects
            self[property.name] = if ((property.init_method == 'new') && target == 'Time')
              # Using custom time parsing method because Ruby's default method is toooo slow 
              self[key].is_a?(String) ? Time.mktime_with_offset(self[key].dup) : self[key]
            # Float instances don't get initialized with #new
            elsif ((property.init_method == 'new') && target == 'Float')
              cast_float(self[key])
            # 'boolean' type is simply used to generate a property? accessor method
            elsif ((property.init_method == 'new') && target == 'boolean')
              self[key]
            else
              # Let people use :send as a Time parse arg
              klass = ::CouchRest.constantize(target)
              klass.send(property.init_method, self[key].dup)   
            end  
            self[property.name].casted_by = self if self[property.name].respond_to?(:casted_by)
          end 
          
        end
        
        def cast_float(value)
          begin 
            Float(value)
          rescue 
            value
          end
        end
        
      end
      
      module ClassMethods
        
        def property(name, options={})
          existing_property = self.properties.find{|p| p.name == name.to_s}
          if existing_property.nil? || (existing_property.default != options[:default])
            define_property(name, options)
          end
        end
        
        # return an array with the names of the properties (aliases not included)
        def property_names
          self.properties.map { |p| p.name }
        end
        
        
        protected
        
          # This is not a thread safe operation, if you have to set new properties at runtime
          # make sure to use a mutex.
          def define_property(name, options={})
            # check if this property is going to casted
            options[:casted] = options[:cast_as] ? options[:cast_as] : false
            
            property = CouchRest::Property.new(name, (options.delete(:cast_as) || options.delete(:type)), options)
            create_property_getter(property) 
            create_property_setter(property) unless property.read_only == true
            properties << property
          end
          
          # defines the getter for the property (and optional aliases)
          def create_property_getter(property)
            # meth = property.name
            class_eval <<-EOS, __FILE__, __LINE__
              def #{property.name}
                self['#{property.name}']
              end
            EOS

            if property.type == 'boolean'
              class_eval <<-EOS, __FILE__, __LINE__
                def #{property.name}?
                  if self['#{property.name}'].nil? || self['#{property.name}'] == false || self['#{property.name}'].to_s.downcase == 'false'
                    false
                  else
                    true
                  end
                end
              EOS
            end

            if property.alias
              class_eval <<-EOS, __FILE__, __LINE__
                alias #{property.alias.to_sym} #{property.name.to_sym}
              EOS
            end
          end

          # defines the setter for the property (and optional aliases)
          # handles the changed_properties and add the field_changed? method with optional aliases
          def create_property_setter(property)
            meth = property.name
            changed_properties_meth_alias = "changed_properties['#{property.alias.to_sym}'.to_sym] = changed_properties['#{meth.to_sym}']" if property.alias
            class_eval <<-EOS
              def #{meth}=(value)
                if self.keys.include?('#{meth}') && self['#{meth}'] != value
                  changed_properties['#{meth}'.to_sym] = self['#{meth}']
                  #{changed_properties_meth_alias}
                elsif !self.keys.include?('#{meth}')
                  changed_properties['#{meth}'.to_sym] = nil
                  #{changed_properties_meth_alias}
                else
                  # nothing to do
                end
                self['#{meth}'] = value
              end
              def #{meth}_changed?
                @changed_properties.include?('#{meth}'.to_sym)
              end
            EOS

            if property.alias
              changed_method = "#{meth}_changed?"
              changed_method_alias = "#{property.alias}_changed?"
              class_eval <<-EOS
                alias #{property.alias.to_sym}= #{meth.to_sym}=
                alias #{changed_method_alias.to_sym} #{changed_method.to_sym}
              EOS
            end
          end

          
      end # module ClassMethods
      
    end
  end
end